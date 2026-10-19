// TPA 识别方法论验证: ①频带能量定性 ②jitter-油门曲线定量
import { readFileSync } from 'fs';
const stubElem = { css(){}, get(){ return []; }, remove(){}, addClass(){}, removeClass(){}, toggleClass(){}, text(){}, html(){}, attr(){}, getBoundingClientRect(){ return {top:0,left:0,width:0,height:0}; }, length: 0 };
globalThis.$ = Object.assign(() => stubElem, { extend(a, ...r) { for (const o of r) for (const k of Object.keys(o || {})) a[k] = o[k]; return a; } });
const _svp = (s) => String(s).split(/[.\-+]/).map(Number);
const _svc = (v, c) => { const a = _svp(v), b = _svp(c); for (let i = 0; i < 3; i++) if ((a[i]||0) !== (b[i]||0)) return (a[i]||0) > (b[i]||0) ? 1 : -1; return 0; };
globalThis.semver = { gte:(v,c)=>_svc(v,c)>=0, lt:(v,c)=>_svc(v,c)<0, gt:(v,c)=>_svc(v,c)>0, lte:(v,c)=>_svc(v,c)<=0, eq:(v,c)=>_svc(v,c)===0 };
const { FlightLogParser } = await import('/tmp/blv_src/flightlog_parser.js');
const { FlightLogIndex } = await import('/tmp/blv_src/flightlog_index.js');

// 简易 radix-2 FFT (N=512)
function fft(re, im) {
    const n = re.length;
    for (let i = 1, j = 0; i < n; i++) {
        let bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) { [re[i], re[j]] = [re[j], re[i]]; [im[i], im[j]] = [im[j], im[i]]; }
    }
    for (let len = 2; len <= n; len <<= 1) {
        const ang = -2 * Math.PI / len, wr = Math.cos(ang), wi = Math.sin(ang);
        for (let i = 0; i < n; i += len) {
            let cr = 1, ci = 0;
            for (let k = 0; k < len / 2; k++) {
                const ur = re[i + k], ui = im[i + k];
                const vr = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci;
                const vi = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr;
                re[i + k] = ur + vr; im[i + k] = ui + vi;
                re[i + k + len / 2] = ur - vr; im[i + k + len / 2] = ui - vi;
                const ncr = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = ncr;
            }
        }
    }
}

// gyro帧序列 → 频带能量占比 (去均值+汉宁窗+FFT, 段长512)
function bandEnergy(seq) {
    const N = 512;
    const out = { low: 0, mid: 0, high: 0, mech: 0, total: 0, peakHz: 0, peakPow: 0, count: 0 };
    for (let s = 0; s + N <= seq.length; s += N) {
        const seg = seq.slice(s, s + N);
        const mean = seg.reduce((a, b) => a + b, 0) / N;
        const re = [], im = [];
        for (let i = 0; i < N; i++) {
            const w = 0.5 * (1 - Math.cos(2 * Math.PI * i / (N - 1)));
            re.push((seg[i] - mean) * w); im.push(0);
        }
        fft(re, im);
        for (let k = 1; k < N / 2; k++) {
            const pw = re[k] * re[k] + im[k] * im[k];
            const hz = k * 1000 / N;   // 1kHz采样
            out.total += pw;
            if (hz < 30) out.low += pw;
            else if (hz < 150) out.mid += pw;
            else if (hz < 300) out.high += pw;
            else out.mech += pw;
            if (hz >= 20 && pw > out.peakPow) { out.peakPow = pw; out.peakHz = hz; }
        }
        out.count++;
    }
    return out;
}

const rounds = ['2轮', '3轮', '6轮'];
for (const r of rounds) {
    const ab = new Uint8Array(readFileSync(`/Users/liangjuan/PID_Liner/吴飞行迭代/${r}.bbl`));
    const index = new FlightLogIndex(ab);
    const parser = new FlightLogParser(ab);
    const frames = [];
    parser.onFrameReady = function (fv, frame, ft) { if (fv && (ft === 'P' || ft === 'I')) frames.push(Array.from(frame)); };
    parser.parseHeader(index.getLogBeginOffset(0), index.getLogBeginOffset(1) ?? ab.length);
    parser.parseLogData(false);
    const idx = {}; parser.frameDefs.I.name.forEach((n, i) => (idx[n] = i));

    // 按油门拆成高/低两段各自的 roll gyro 序列(不连续也行,FFT按段算)
    const loSeq = [], hiSeq = [];
    // jitter-油门曲线: 每200PWM一桶
    const buckets = {};
    for (let i = 1; i < frames.length; i++) {
        const thr = frames[i][idx['rcCommand[3]']];
        if (thr < 1000 || thr > 2000) continue;
        const b = Math.floor((thr - 1000) / 200) * 200 + 1100;   // 桶中心 1100,1300,...1900
        const j = Math.abs(frames[i][idx['gyroADC[0]']] - frames[i - 1][idx['gyroADC[0]']]);
        (buckets[b] = buckets[b] || []).push(j);
        (thr >= 1350 ? hiSeq : loSeq).push(frames[i][idx['gyroADC[0]']]);
    }

    const lo = bandEnergy(loSeq), hi = bandEnergy(hiSeq);
    const pct = (x, t) => (x / (t || 1) * 100).toFixed(1);
    console.log(`\n===== ${r} (滑块: pi/i/d 见前表) =====`);
    console.log(`  低油门 gyro 频带能量占比: <30Hz ${pct(lo.low,lo.total)}% | 30-150Hz ${pct(lo.mid,lo.total)}% | 150-300Hz ${pct(lo.high,lo.total)}% | 300Hz+ ${pct(lo.mech,lo.total)}% | 主峰 ${lo.peakHz.toFixed(0)}Hz`);
    console.log(`  高油门 gyro 频带能量占比: <30Hz ${pct(hi.low,hi.total)}% | 30-150Hz ${pct(hi.mid,hi.total)}% | 150-300Hz ${pct(hi.high,hi.total)}% | 300Hz+ ${pct(hi.mech,hi.total)}% | 主峰 ${hi.peakHz.toFixed(0)}Hz`);
    console.log(`  jitter-油门曲线 (roll, 桶宽200PWM):`);
    const keys = Object.keys(buckets).map(Number).sort((a, b) => a - b);
    for (const k of keys) {
        if (buckets[k].length < 200) continue;
        const m = median(buckets[k]).toFixed(1);
        const bar = '█'.repeat(Math.min(40, Math.round(median(buckets[k]))));
        console.log(`    ${String(k).padStart(4)}-${String(k + 199).padEnd(4)}: ${m.padStart(5)}  ${bar}${k <= 1350 && k + 199 >= 1150 ? '  ←bp=1350' : ''}`);
    }
}
function median(a) { if (!a.length) return NaN; const s = [...a].sort((x, y) => x - y); return s[s.length >> 1]; }
