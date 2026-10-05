## Results: ruby-zjit-20261005

mean ± sd across reps (Ruby head ZJIT n=3). Each rep is a fresh container on a fresh seed copy.

```
date: 2026-10-05T22:38:29+00:00
host: 7.0.0-34-generic, AMD Ryzen Threadripper PRO 7975WX 32-Cores, 63 threads, 243GB
server cpus: 8-11 (nproc 4); loadgen cpus: 12-15; network: host
env: WEB_CONCURRENCY=3 JOB_CONCURRENCY=3 RAILS_MAX_THREADS=5 
rust extra env: 
user agent: (none)
ruby-zjit image: campfire-ruby:head sha256:fc24cfdd233a78a2d0c5f67eee9697bc2ed30dbcd985478b71dd9575e5a6c80a 2026-10-05T22:33:35.578993667Z
rust HEAD: 64f8635 (dirty: 0 files)
```

### HTTP room_show

| Metric | Ruby head ZJIT |
|---|---:|
| c=1 req/s | 1,729 ± 50.6 |
| c=1 p50 ms | 0.57 ± 0.01 |
| c=1 p90 ms | 0.66 ± 0.02 |
| c=1 p99 ms | 0.74 ± 0.03 |
| c=1 non-2xx/3xx | 0.00 ± 0.00 |
| c=16 req/s | 5,984 ± 70.0 |
| c=16 p50 ms | 2.62 ± 0.02 |
| c=16 p90 ms | 2.79 ± 0.02 |
| c=16 p99 ms | 3.51 ± 0.90 |
| c=16 non-2xx/3xx | 0.00 ± 0.00 |
| c=64 req/s | 5,691 ± 35.4 |
| c=64 p50 ms | 11.0 ± 0.06 |
| c=64 p90 ms | 11.5 ± 0.07 |
| c=64 p99 ms | 21.3 ± 0.05 |
| c=64 non-2xx/3xx | 0.00 ± 0.00 |

### HTTP messages_page

| Metric | Ruby head ZJIT |
|---|---:|
| c=1 req/s | 3,365 ± 43.6 |
| c=1 p50 ms | 0.29 ± 0.00 |
| c=1 p90 ms | 0.36 ± 0.01 |
| c=1 p99 ms | 0.41 ± 0.01 |
| c=1 non-2xx/3xx | 0.00 ± 0.00 |
| c=16 req/s | 12,076 ± 71.1 |
| c=16 p50 ms | 1.21 ± 0.33 |
| c=16 p90 ms | 1.81 ± 0.19 |
| c=16 p99 ms | 1.96 ± 0.20 |
| c=16 non-2xx/3xx | 0.00 ± 0.00 |
| c=64 req/s | 11,388 ± 89.3 |
| c=64 p50 ms | 5.09 ± 0.91 |
| c=64 p90 ms | 8.38 ± 2.62 |
| c=64 p99 ms | 8.90 ± 2.67 |
| c=64 non-2xx/3xx | 0.00 ± 0.00 |

### HTTP sidebar

| Metric | Ruby head ZJIT |
|---|---:|
| c=1 req/s | 2,019 ± 36.6 |
| c=1 p50 ms | 0.49 ± 0.01 |
| c=1 p90 ms | 0.55 ± 0.02 |
| c=1 p99 ms | 0.61 ± 0.01 |
| c=1 non-2xx/3xx | 0.00 ± 0.00 |
| c=16 req/s | 7,416 ± 96.2 |
| c=16 p50 ms | 2.23 ± 0.22 |
| c=16 p90 ms | 3.03 ± 0.64 |
| c=16 p99 ms | 3.29 ± 0.68 |
| c=16 non-2xx/3xx | 0.00 ± 0.00 |
| c=64 req/s | 7,245 ± 83.4 |
| c=64 p50 ms | 8.58 ± 0.44 |
| c=64 p90 ms | 12.4 ± 1.73 |
| c=64 p99 ms | 13.0 ± 1.75 |
| c=64 non-2xx/3xx | 0.00 ± 0.00 |

### HTTP search

| Metric | Ruby head ZJIT |
|---|---:|
| c=1 req/s | 2,240 ± 30.2 |
| c=1 p50 ms | 0.44 ± 0.00 |
| c=1 p90 ms | 0.52 ± 0.01 |
| c=1 p99 ms | 0.59 ± 0.02 |
| c=1 non-2xx/3xx | 0.00 ± 0.00 |
| c=16 req/s | 8,078 ± 72.1 |
| c=16 p50 ms | 1.93 ± 0.24 |
| c=16 p90 ms | 2.82 ± 0.72 |
| c=16 p99 ms | 3.05 ± 0.76 |
| c=16 non-2xx/3xx | 0.00 ± 0.00 |
| c=64 req/s | 7,785 ± 57.8 |
| c=64 p50 ms | 7.22 ± 1.17 |
| c=64 p90 ms | 12.0 ± 2.72 |
| c=64 p99 ms | 18.7 ± 0.68 |
| c=64 non-2xx/3xx | 0.00 ± 0.00 |

### HTTP avatar

| Metric | Ruby head ZJIT |
|---|---:|
| c=1 req/s | 18,675 ± 401 |
| c=1 p50 ms | 0.05 ± 0.00 |
| c=1 p90 ms | 0.06 ± 0.00 |
| c=1 p99 ms | 0.12 ± 0.00 |
| c=1 non-2xx/3xx | 0.00 ± 0.00 |
| c=16 req/s | 113,093 ± 3,314 |
| c=16 p50 ms | 0.13 ± 0.01 |
| c=16 p90 ms | 0.20 ± 0.01 |
| c=16 p99 ms | 0.26 ± 0.03 |
| c=16 non-2xx/3xx | 0.00 ± 0.00 |
| c=64 req/s | 111,215 ± 2,172 |
| c=64 p50 ms | 0.58 ± 0.04 |
| c=64 p90 ms | 0.73 ± 0.08 |
| c=64 p99 ms | 0.86 ± 0.07 |
| c=64 non-2xx/3xx | 0.00 ± 0.00 |

### HTTP static_css

| Metric | Ruby head ZJIT |
|---|---:|
| c=1 req/s | 21,098 ± 740 |
| c=1 p50 ms | 0.04 ± 0.00 |
| c=1 p90 ms | 0.05 ± 0.00 |
| c=1 p99 ms | 0.11 ± 0.00 |
| c=1 non-2xx/3xx | 0.00 ± 0.00 |
| c=16 req/s | 120,340 ± 7,420 |
| c=16 p50 ms | 0.13 ± 0.02 |
| c=16 p90 ms | 0.22 ± 0.05 |
| c=16 p99 ms | 0.28 ± 0.03 |
| c=16 non-2xx/3xx | 0.00 ± 0.00 |
| c=64 req/s | 129,190 ± 1,090 |
| c=64 p50 ms | 0.49 ± 0.03 |
| c=64 p90 ms | 0.63 ± 0.04 |
| c=64 p99 ms | 0.75 ± 0.04 |
| c=64 non-2xx/3xx | 0.00 ± 0.00 |

### HTTP up

| Metric | Ruby head ZJIT |
|---|---:|
| c=1 req/s | 12,277 ± 743 |
| c=1 p50 ms | 0.08 ± 0.00 |
| c=1 p90 ms | 0.09 ± 0.01 |
| c=1 p99 ms | 0.15 ± 0.01 |
| c=1 non-2xx/3xx | 0.00 ± 0.00 |
| c=16 req/s | 65,112 ± 3,975 |
| c=16 p50 ms | 0.20 ± 0.03 |
| c=16 p90 ms | 0.43 ± 0.12 |
| c=16 p99 ms | 0.58 ± 0.17 |
| c=16 non-2xx/3xx | 0.00 ± 0.00 |
| c=64 req/s | 62,796 ± 2,685 |
| c=64 p50 ms | 1.02 ± 0.05 |
| c=64 p90 ms | 1.25 ± 0.10 |
| c=64 p99 ms | 1.73 ± 0.30 |
| c=64 non-2xx/3xx | 0.00 ± 0.00 |

### HTTP post_message

| Metric | Ruby head ZJIT |
|---|---:|
| c=1 req/s | 1,009 ± 12.9 |
| c=1 p50 ms | 0.88 ± 0.01 |
| c=1 p90 ms | 1.09 ± 0.03 |
| c=1 p99 ms | 2.36 ± 0.20 |
| c=1 non-2xx/3xx | 0.00 ± 0.00 |
| c=16 req/s | 1,809 ± 116 |
| c=16 p50 ms | 8.01 ± 0.63 |
| c=16 p90 ms | 13.6 ± 2.21 |
| c=16 p99 ms | 33.9 ± 4.86 |
| c=16 non-2xx/3xx | 0.00 ± 0.00 |
| c=64 req/s | 1,609 ± 150 |
| c=64 p50 ms | 33.7 ± 1.67 |
| c=64 p90 ms | 58.6 ± 3.11 |
| c=64 p99 ms | 248 ± 258 |
| c=64 non-2xx/3xx | 0.00 ± 0.00 |

### Action Cable fan-out

| Metric | Ruby head ZJIT |
|---|---:|
| 100 clients: delivery p50 ms | 5.15 ± 0.33 |
| 100 clients: delivery p99 ms | 1,511 ± 2,579 |
| 100 clients: delivered msg/s | 1,240 ± 28.6 |
| 500 clients: delivery p50 ms | 8.73 ± 1.03 |
| 500 clients: delivery p99 ms | 121 ± 169 |
| 500 clients: delivered msg/s | 437 ± 61.5 |
| 1000 clients: delivery p50 ms | 13.5 ± 1.40 |
| 1000 clients: delivery p99 ms | 24.5 ± 8.41 |
| 1000 clients: delivered msg/s | 228 ± 7.72 |

### Process

| Metric | Ruby head ZJIT |
|---|---:|
| cold start ms | 1,092 ± 463 |
| idle memory MB | 70.3 ± 0.58 |
| peak memory MB | 743 ± 36.1 |
| upload median ms | 236 ± 5.12 |
