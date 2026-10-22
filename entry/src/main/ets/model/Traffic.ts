import { NativeSnapshot, VpnSnapshot } from './VpnModels';

// OpenVPN3 tun_stats: bytesIn/packetsIn = downloaded IP data delivered to TUN;
// bytesOut/packetsOut = uploaded IP data read from TUN. Excludes TLS/transport overhead.
export class Traffic {
  private previous: number[] = [0, 0, 0, 0];
  private previousTime: number = 0;

  sample(native: NativeSnapshot, snapshot: VpnSnapshot, monotonicMs: number): void {
    const values = [native.bytesIn, native.bytesOut, native.packetsIn, native.packetsOut];
    const deltas: number[] = [];
    for (let i = 0; i < values.length; i++) {
      const current = Number.isFinite(values[i]) && values[i] >= 0 ? values[i] : this.previous[i];
      // A core reconnect can reset a counter. Add the new segment once.
      deltas.push(current >= this.previous[i] ? current - this.previous[i] : current);
      this.previous[i] = current;
    }
    snapshot.downloadBytes += deltas[0];
    snapshot.uploadBytes += deltas[1];
    snapshot.downloadPackets += deltas[2];
    snapshot.uploadPackets += deltas[3];
    const elapsed = monotonicMs - this.previousTime;
    snapshot.downloadRate = this.previousTime > 0 && elapsed >= 100 && elapsed <= 10000 ? deltas[0] * 1000 / elapsed : 0;
    snapshot.uploadRate = this.previousTime > 0 && elapsed >= 100 && elapsed <= 10000 ? deltas[1] * 1000 / elapsed : 0;
    this.previousTime = monotonicMs;
  }
}
