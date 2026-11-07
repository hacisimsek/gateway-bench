# S1 passthrough — median of runs

```
date: 2026-11-07T14:11:24Z
host: Apple M4 Pro, docker cpus=12 mem=8321429504
commit: 5435598-dirty
limits: gateways 2 cpu/512m, upstream 4 cpu, k6 4 cpu
java options: -XX:+UseG1GC
```

| target | rate | achieved rps | p50 ms | p95 ms | p99 ms | errors % | dropped | cpu % | mem MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| java | 1000 | 1000 | 0.57 | 1.15 | 2.51 | 0.00 | 0 | 48 | 390 |
| java | 5000 | 5000 | 0.30 | 0.73 | 3.29 | 0.00 | 0 | 108 | 387 |
| java | 10000 | 9992 | 0.37 | 1.93 | 5.51 | 0.00 | 229 | 162 | 511 |
| java | 20000 | 7499 | 152.87 | 314.27 | 4745.69 | 0.00 | 373391 | 193 | 511 |
