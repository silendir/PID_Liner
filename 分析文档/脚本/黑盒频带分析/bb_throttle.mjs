// 油门分桶画像: 验证 AG不足/TPA过度/不足 信号是否存在于 6 轮 BBL
import { readFileSync } from 'fs';
const stubElem = { css(){}, get(){ return []; }, remove(){}, addClass(){}, removeClass(){}, toggleClass(){}, text(){}, html(){}, attr(){}, getBoundingClientRect(){ return {top:0,left:0,width:0,height:0}; }, length: 0 };
globalThis.$ = Object.assign(() => stubElem, { extend(a, ...r) { for (const o of r) for (const k of Object.keys(o || {})) a[k] = o[k]; return a; } });
const _svp = (s) => String(s).split(/[.\-+]/).map(Number);
const _svc = (v, c) => { const a = _svp(v), b = _svp(c); for (let i = 0; i < 3; i++) if ((a[i]||0) !== (b[i]||0)) return (a[i]||0) > (b[i]||0) ? 1 : -1; return 0; };
globalThis.semver = { gte:(v,c)=>_svc(v,c)>=0, lt:(v,c)=>_svc(v,c)<0, gt:(v,c)=>_svc(v,c)>0, lte:(v,c)=>_svc(v,c)<=0, eq:(v,c)=>_svc(v,c)===0 };
const { FlightLogParser } = await import('/tmp/blv_src/flightlog_parser.js');
const { FlightLogIndex } = await import('/tmp/blv_src/flightlog_index.js');

const rounds = ['首轮', '2轮', '3轮', '4轮', '5轮', '6轮'];
const BP = 1350;   // 

function median(a) { if (!a.length) return NaN; const s = [...a].sort((x, y) => x - y); return s[s.length >> 1]; }

console.log('轮次 | 油门中位 | 高油门帧 | 突变帧占比 | 响应增益 低油门→高油门 (比值) | jitter 低→高 (比值) | 信号判定');
console.log('-----+---------+---------+-----------+------------------------------+--------------------+--------');

for (const r of rounds) {
    const ab = new Uint8Array(readFileSync(`/Users/liangjuan/PID_Liner/吴飞行迭代/${r}.bbl`));
    const index = new FlightLogIndex(ab);
    // 取帧数最多的 log(首轮含2段,取正式飞那段)
    let best = null;
    for (let li = 0; li < index.getLogCount(); li++) {
        const parser = new FlightLogParser(ab);
        const frames = [];
        parser.onFrameReady = function (fv, frame, ft) { if (fv && (ft === 'P' || ft === 'I')) frames.push(Array.from(frame)); };
        try {
            parser.parseHeader(index.getLogBeginOffset(li), index.getLogBeginOffset(li + 1) ?? ab.length);
            parser.parseLogData(false);
        } catch (e) { continue; }
        if (!best || frames.length > best.frames.length) best = { frames, parser };
    }
    const frames = best.frames;
    const idx = {}; best.parser.frameDefs.I.name.forEach((n, i) => (idx[n] = i));
    const hasD = idx['axisD[0]'] !== undefined;

    // 帧级分桶
    const loGain = [], hiGain = [], loJit = [], hiJit = [];
    let hiCount = 0, jumpFrames = 0;
    const thrSamples = [];
    for (let i = 5; i < frames.length; i++) {
        const thr = frames[i][idx['rcCommand[3]']];
        if (i % 20 === 0) thrSamples.push(thr);
        // 油门突变: 100ms 内变化 > 120 (AG 触发场景)
        if (Math.abs(frames[i][idx['rcCommand[3]']] - frames[i - 5][idx['rcCommand[3]']]) > 120) jumpFrames++;

        const hi = thr >= BP;
        if (hi) hiCount++;

        // 机动帧(|E|>100)的响应增益与 jitter,三轴平均
        let gSum = 0, eSum = 0, jSum = 0, n = 0;
        for (let a = 0; a < 3; a++) {
            const E = frames[i][idx[`setpoint[${a}]`]] - frames[i][idx[`gyroADC[${a}]`]];
            if (Math.abs(E) > 100) {
                const gy = Math.abs(frames[i][idx[`gyroADC[${a}]`]]);
                gSum += gy / Math.abs(E);          // 响应增益: |gyro|/|误差|
                jSum += Math.abs(frames[i][idx[`gyroADC[${a}]`]] - frames[i - 1][idx[`gyroADC[${a}]`]]);
                n++;
            }
        }
        if (n >= 2) {
            if (hi) { hiGain.push(gSum / n); hiJit.push(jSum / n); }
            else    { loGain.push(gSum / n); loJit.push(jSum / n); }
        }
    }
    thrSamples.sort((a, b) => a - b);
    const thrMed = median(thrSamples);
    const hiPct = (hiCount / frames.length * 100).toFixed(0);
    const jumpPct = (jumpFrames / frames.length * 100).toFixed(1);
    const gLo = median(loGain), gHi = median(hiGain);
    const jLo = median(loJit), jHi = median(hiJit);
    const gRatio = (gHi / gLo).toFixed(2);
    const jRatio = (jHi / jLo).toFixed(2);

    // 信号判定
    let verdict = [];
    if (parseFloat(gRatio) < 0.7) verdict.push('TPA过度?(高油门增益低30%+)');
    if (parseFloat(jRatio) > 1.5) verdict.push('TPA不足?(高油门jitter高50%+)');
    if (parseFloat(gRatio) > 1.0 && parseFloat(jRatio) < 1.2) verdict.push('高油门区间正常');
    if (parseInt(jumpPct) === 0) verdict.push('无油门突变,AG无介入场景');

    console.log(`${r.padEnd(4)} | ${String(thrMed).padStart(7)} | ${hiPct.padStart(7)}% | ${jumpPct.padStart(8)}% | ${gLo.toFixed(2)}→${gHi.toFixed(2)} (${gRatio}) | ${jLo.toFixed(1)}→${jHi.toFixed(1)} (${jRatio}) | ${verdict.join(' ') || '-'}`);
}
console.log('\n响应增益=|gyro|/|误差|(机动帧,值大=跟手); jitter=gyro帧间差分(值大=抖); 比值>1=高油门更甚');
console.log('TPA判定参考: 增益比<0.7=过度(发软) / jitter比>1.5=不足(共振); 无油门突变场景则AG无从诊断');
