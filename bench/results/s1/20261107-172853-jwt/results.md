# S1 passthrough — median of runs

```
date: 2026-11-07T14:28:53Z
host: Apple M4 Pro, docker cpus=12 mem=8321429504
commit: 0f7dbb6-dirty
limits: gateways 2 cpu/512m, upstream 4 cpu, k6 4 cpu
jwt: yes (RS256, verified on every request)
java options:
```

| target | rate | achieved rps | p50 ms | p95 ms | p99 ms | errors % | dropped | cpu % | mem MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| rust | 1000 | 1000 | 0.36 | 0.87 | 1.95 | 0.00 | 0 | 19 | 54 |
| java | 1000 | 1000 | 0.57 | 0.96 | 2.09 | 0.00 | 0 | 53 | 494 |
| rust | 5000 | 5000 | 0.22 | 0.54 | 1.92 | 0.00 | 0 | 40 | 55 |
| java | 5000 | 5000 | 0.40 | 1.31 | 4.27 | 0.00 | 0 | 137 | 499 |
| rust | 10000 | 9994 | 0.19 | 0.52 | 1.98 | 0.00 | 162 | 64 | 78 |
| java | 10000 | 1800 | 1067.00 | 1958.37 | 2527.41 | 0.00 | 245126 | 120 | 512 |
| rust | 20000 | 19944 | 0.31 | 0.96 | 4.81 | 0.00 | 1650 | 99 | 98 |
| java | 20000 | 1667 | 1192.09 | 2062.60 | 2658.78 | 0.00 | 548635 | 113 | 510 |
