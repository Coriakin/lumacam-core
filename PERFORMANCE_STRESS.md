## LumaCam Core performance + long-session stress checklist

This repo is consumed by the LumaCam apps as a Swift package. The app repo typically owns the renderer/decoder, but `lumacam-core` contains key RTSP/network/parser logic that can drive long-session stability.

### Repro/stress scenarios (recommended)

#### Rapid connect/disconnect loop
- **Goal**: detect leaked tasks/connections and resource churn.
- **Run**: 100–500 iterations.
- **Variants**:
  - immediate disconnect after connect request
  - disconnect while “connecting”
  - switch between 1 and 2 streams every N iterations

#### Offline host / no-route / DNS failure
- **Goal**: ensure connection attempts time out and tear down promptly.
- **Cases**:
  - IP that is unroutable
  - hostname that fails DNS
  - host that accepts TCP then stalls (no RTSP response)

#### Coalesced/pipelined reads
- **Goal**: validate buffer parsing does not drop bytes when reads contain multiple protocol units.
- **Cases**:
  - RTSP response immediately followed by `$` interleaved frame bytes
  - back-to-back RTSP responses in one read (server pipelining)

#### Long steady streaming session
- **Goal**: detect gradual RAM growth, frame latency creep, CPU drift.
- **Run**: 60–120 minutes.
- **Variants**:
  - periodic Wi‑Fi drops / airplane-mode toggles
  - switching between cameras / profiles every 5–10 minutes
  - 1 stream vs 2 streams comparison (same resolution/bitrate)

### Instruments verification (what to look for)

#### Leaks + Memory Graph
- **Look for**:
  - retained `NWConnection` instances after disconnect
  - retained async `Task` trees that should have been cancelled
  - unexpected growth of `Data` / `NSData` buffers

#### Allocations
- **Look for**:
  - sustained high allocation rate in parsing and sample construction code paths
  - `Data` growth that never returns to baseline after reconnect cycles
- **Compare**:
  - 1 stream vs 2 streams (allocation rate should scale roughly linearly)

#### Time Profiler
- **Look for**:
  - time in RTSP parsing, interleaved frame parsing, RTP parsing, and sample construction
  - time in buffer shifting/copying (e.g. `removeSubrange`/memmove behavior)

#### Energy Log
- **Look for**:
  - CPU use drift over time (e.g. backlog-related churn)
  - spikes during reconnect storms

#### Thread Sanitizer + Main Thread Checker
- **Goal**: ensure decode/network work stays off the main thread and shared state is properly isolated per stream.

### Notes on keepalive / TEARDOWN
- RTSP servers vary. Some need periodic `OPTIONS`/`GET_PARAMETER` keepalive; some don’t.
- Prefer making keepalive **configurable** and validating against the target camera set.
- `TEARDOWN` compatibility also varies; still worth supporting where possible to avoid server-side session leaks.

