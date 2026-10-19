// 各轮等效P增益对比: Kp_est = median(axisP/(setpoint-gyro)) 机动段,跨轮比值=实际增益比
import { readFileSync } from 'fs';
const stubElem = { css(){}, get(){ return []; }, remove(){}, addClass(){}, removeClass(){}, toggleClass(){}, text(){}, html(){}, attr(){}, getBoundingClientRect(){ return {top:0,left:0,width:0,height:0}; }, length: 0 };
globalThis.$ = Object.assign(() => stubElem, { extend(a, ...r) { for (const o of r) for (const k of Object.keys(o || {})) a[k] = o[k]; return a; } });
const _svp = (s) => String(s).split(/[.\-+]/).map(Number);
const _svc = (v, c) => { const a = _svp(v), b = _svp(c); for (let i = 0; i < 3; i++) if ((a[i]||0) !== (b[i]||0)) return (a[i]||0) > (b[i]||0) ? 1 : -1; return 0; };
globalThis.semver = { gte:(v,c)=>_svc(v,c)>=0, lt:(v,c)=>_svc(v,c)<0, gt:(v,c)=>_svc(v,c)>0, lte:(v,c)=>_svc(v,c)<=0, eq:(v,c)=>_svc(v,c)===0 };
const { FlightLogParser } = await import('/tmp/blv_src/flightlog_parser.js');
const { FlightLogIndex } = await import('/tmp/blv_src/flightlog_index.js');

const rounds = ['首轮', '2轮', '3轮', '4轮', '5轮', '6轮'];
const sliders = { '首轮':'pi130/105/110 ppi100', '2轮':'pi100 i100 d115 ppi100', '3轮':'pi75 i133 d130', '4轮':'pi100 i100 d130 ppi75', '5轮':'pi100 i100 d130 ppi75', '6轮':'pi100 i100 d130 ppi100' };

function median(a) { if (!a.length) return NaN; const s = [...a].sort((x, y) => x - y); return s[s.length >> 1]; }

console.log('轮次  | 滑块                      | Kp_est 中位 (Roll/Pitch/Yaw)          | 机动帧数');
console.log('------+--------------------------+--------------------------------------+--------');
for (const r of rounds) {
    const ab = new Uint8Array(readFileSync(`/Users/liangjuan/PID_Liner/吴飞行迭代/${r}.bbl`));
    const index = new FlightLogIndex(ab);
    const parser = new FlightLogParser(ab);
    const frames = [];
    parser.onFrameReady = function (fv, frame, ft) { if (fv && (ft === 'P' || ft === 'I')) frames.push(Array.from(frame)); };
    try { parser.parseHeader(index.getLogBeginOffset(0), index.getLogBeginOffset(1) ?? ab.length); parser.parseLogData(false); }
    catch (e) { console.log(`${r}: 解析失败 ${e}`); continue; }
    const idx = {}; parser.frameDefs.I.name.forEach((n, i) => (idx[n] = i));

    const est = [[], [], []];
    for (let i = 0; i < frames.length; i++) {
        for (let a = 0; a < 3; a++) {
            const sp = frames[i][idx[`setpoint[${a}]`]];
            const gy = frames[i][idx[`gyroADC[${a}]`]];
            const E = sp - gy;
            if (Math.abs(E) > 80) {   // 机动段:误差足够大,P主导
                est[a].push(frames[i][idx[`axisP[${a}]`]] / E);
            }
        }
    }
    const m = est.map(x => median(x).toFixed(2));
    console.log(`${r.padEnd(5)} | ${sliders[r].padEnd(24)} | ${m.join(' / ').padEnd(36)} | ${est[0].length}`);
}
console.log('\nKp_est=axisP/(setpoint-gyro) 中位数,内部单位(跨轮相对值有效);滑块pi=75的轮次若Kp_est低25%即证实滑块实时生效');
