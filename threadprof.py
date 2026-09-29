#!/usr/bin/env python3
"""Per-thread / per-core CPU sampler for minicast (DOA2 dip hunting).

Waits for the next minicast process, then once a second logs: seconds since
start, busy % of each core, and the busiest threads (tid, %, core, state).
Output: /tmp/threadprof.log. Stops when minicast exits.
"""
import os
import time

OUT = "/tmp/threadprof.log"
NAMES = ("minicast-crt-tacore.elf", "minicast-crt-r7.elf", "minicast-crt-tacore-trace.elf")
HZ = os.sysconf("SC_CLK_TCK")


def find_pid():
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open("/proc/%s/cmdline" % pid, "rb") as f:
                exe = f.read().split(b"\0")[0].decode(errors="replace")
        except OSError:
            continue
        if os.path.basename(exe) in NAMES:
            return int(pid)
    return None


def core_times():
    out = {}
    with open("/proc/stat") as f:
        for line in f:
            if line.startswith("cpu") and line[3].isdigit():
                p = line.split()
                vals = list(map(int, p[1:]))
                idle = vals[3] + vals[4]
                out[p[0]] = (sum(vals), idle)
    return out


def thread_times(pid):
    out = {}
    for tid in os.listdir("/proc/%d/task" % pid):
        try:
            with open("/proc/%d/task/%s/stat" % (pid, tid)) as f:
                s = f.read()
        except OSError:
            continue
        rest = s[s.rindex(")") + 2:].split()
        # rest[0]=state ... utime=rest[11] stime=rest[12] processor=rest[36]
        out[int(tid)] = (int(rest[11]) + int(rest[12]), rest[36], rest[0])
    return out


def main():
    pid = None
    while pid is None:
        pid = find_pid()
        time.sleep(0.5)
    t0 = time.time()
    with open(OUT, "w", buffering=1) as log:
        log.write("pid %d started\n" % pid)
        prev_c, prev_t, prev_w = core_times(), thread_times(pid), time.time()
        while os.path.exists("/proc/%d" % pid):
            time.sleep(1.0)
            try:
                cur_c, cur_t, now = core_times(), thread_times(pid), time.time()
            except OSError:
                break
            dt = now - prev_w
            cores = []
            for k in sorted(cur_c):
                tot = cur_c[k][0] - prev_c[k][0]
                idle = cur_c[k][1] - prev_c[k][1]
                cores.append("%s %3.0f%%" % (k, 100.0 * (tot - idle) / tot if tot else 0))
            thr = []
            for tid, (ticks, cpu, st) in cur_t.items():
                if tid in prev_t:
                    pct = 100.0 * (ticks - prev_t[tid][0]) / HZ / dt
                    if pct >= 3:
                        thr.append((pct, tid, cpu, st))
            thr.sort(reverse=True)
            log.write("%6.1f | %s | %s\n" % (now - t0, "  ".join(cores),
                      "  ".join("t%d:%3.0f%%@%s%s" % (tid, pct, cpu, st) for pct, tid, cpu, st in thr[:6])))
            prev_c, prev_t, prev_w = cur_c, cur_t, now
        log.write("minicast exited\n")


if __name__ == "__main__":
    main()
