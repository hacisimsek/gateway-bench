# S1 passthrough — median of runs

```
date: 2026-11-08T09:51:12Z
host: Apple M4 Pro, docker cpus=12 mem=8321429504
commit: 898730e-dirty
limits: gateways 2 cpu/512m, upstream 4 cpu, k6 4 cpu
jwt: yes (RS256, verified on every request)
rate limit: BURST=1000000  PER_SECOND=1000000 
java options:
```

| target | rate | achieved rps | p50 ms | p95 ms | p99 ms | errors % | dropped | cpu % | mem MiB | redis cpu % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| rust | 1000 | 1000 | 0.46 | 1.23 | 1.90 | 0.00 | 0 | 23 | 48 | 6 |
| java | 1000 | 57 | 0.00 | 0.00 | 0.00 | 100.00 | 28001 | 95 | 512 | 0 |
| rust | 5000 | 5000 | 0.22 | 0.50 | 0.89 | 0.00 | 0 | 45 | 50 | 10 |
| java | 5000 | 60 | 0.00 | 0.00 | 0.00 | 100.00 | 147993 | 95 | 512 | 0 |
| rust | 10000 | 10000 | 0.30 | 0.64 | 1.30 | 0.00 | 0 | 79 | 55 | 16 |
| java | 10000 | 61 | 0.00 | 0.00 | 0.00 | 100.00 | 298000 | 99 | 512 | 0 |
| rust | 20000 | 19974 | 0.54 | 2.36 | 12.13 | 0.00 | 738 | 132 | 56 | 25 |
| java | 20000 | 63 | 0.00 | 0.00 | 0.00 | 100.00 | 598032 | 9 | 512 | 1 |
