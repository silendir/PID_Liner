// 各轮 BBL 实际运行 PID 输出对比(axisP/axisI 中位数,验证滑块实时生效模型)
import { readFileSync } from 'fs';

const stubElem = { css(){}, get(){ return []; }, remove(){}, addClass(){}, removeClass(){}, toggleClass(){}, text(){}, html(){}, attr(){}, getBoundingClientRect(){ return {top:0,left:0,width:0,height:0}; }, length: 0 };
globalThis.$ = Object.assign(() => stubElem, { extend(a, ...rest) { for (const o of rest) for (const k of Object.keys(o || {})) a[k] = o[k]; return a; } });
const _svp = (s) => String(s).split(/[.\-+]/).map(Number);
const _svc = (v, c) => { const a = _svp(v), b = _svp(c); for (let i = 0; i < 3; i++) if ((a[i]||0) !== (b[i]||0)) return (a[i]||0) > (b[i]||0) ? 1 : -1; return 0; };
globalThis.semver = { gte:(v,c)=>_svc(v,c)>=0, lt:(v,c)=>_svc(v,c)<0, gt:(v,c)=>_svc(v,c)>0, lte:(v,c)=>_svc(v,c)<=0, eq:(v,c)=>_svc(v,c)===0 };

const { FlightLogParser } = await import('/tmp/blv_src/flightlog_parser.js');
const { FlightLogIndex } = await import('/tmp/blv_src/flightlog_index.js');

const rounds = ['首轮', '2轮', '3轮', '4轮', '5轮', '6轮'];

function median(arr) {
    if (!arr.length) return NaN;
    const s = [...arr].sort((a, b) => a - b);
    return s[Math.floor(s.length / 2)];
}

const table = [];
for (const r of rounds) {
    const ab = new Uint8Array(readFileSync(`/Users/liangjuan/PID_Liner/吴飞行迭代/${r}.bbl`));
    const index = new FlightLogIndex(ab);
    const start = index.getLogBeginOffset(0);
    const parser = new FlightLogParser(ab);
    const frames = [];
    parser.onFrameReady = function (fv, frame, ft) {
        if (fv && (ft === 'P' || ft === 'I')) frames.push(Array.from(frame));
    };
    try {
        parser.parseHeader(start, index.getLogBeginOffset(1) ?? ab.length);
        parser.parseLogData(false);
    } catch (e) { console.log(`${r}: 解析失败 ${e}`); continue; }

    const names = parser.frameDefs.I.name;
    const idx = {};
    names.forEach((n, i) => (idx[n] = i));
    if (idx['axisP[0]'] === undefined) { console.log(`${r}: 缺 axisP 字段`); continue; }

    // 稳态段过滤: |gyroADC[0]|<50 且 |setpoint差|小 → 近悬停/匀速帧,P输出≈P增益×小误差,量级可比
    const pRows = [[], [], []], iRows = [[], [], []], dRows = [[], [], []];
    let gyroActivity = [];
    for (let i = 0; i < frames.length; i++) {
        const g = Math.abs(frames[i][idx['gyroADC[0]']]);
        gyroActivity.push(g);
        if (g < 60 && Math.abs(frames[i][idx['gyroADC[1]']]) < 60 && Math.abs(frames[i][idx['gyroADC[2]']]) < 60) {
            for (let a = 0; a < 3; a++) {
                pRows[a].push(frames[i][idx[`axisP[${a}]`]]);
                iRows[a].push(frames[i][idx[`axisI[${a}]`]]);
                if (idx[`axisD[${a}]`] !== undefined) dRows[a].push(frames[i][idx[`axisD[${a}]`]]);
            }
        }
    }
    const act = gyroActivity.reduce((a, b) => a + b, 0) / gyroActivity.length;
    table.push({
        r, frames: frames.length,
        steadyPct: (pRows[0].length / frames.length * 100).toFixed(0),
        p: pRows.map(x => median(x).toFixed(1)),
        i: iRows.map(x => median(x).toFixed(1)),
        d: dRows.map(x => median(x).toFixed(1)),
        gyroAvg: act.toFixed(0)
    });
}

console.log('轮次  | 帧数   | 稳态占比 | gyro均动 | P输出中位(R/P/Y)   | I输出中位(R/P/Y)   | D输出中位(R/P/Y)');
console.log('------+--------+---------+---------+-------------------+-------------------+-----------------');
for (const t of table) {
    console.log(`${t.r.padEnd(5)} | ${String(t.frames).padEnd(6)} | ${t.steadyPct}% | ${t.gyroAvg.padStart(7)} | ${t.p.join('/').padEnd(17)} | ${t.i.join('/').padEnd(17)} | ${t.d.join('/')}`);
}
console.log('\n稳态段=三轴|gyro|<60的帧(近似悬停/匀速),P/I输出量级与实际增益成正比');
