/// Cell durations are measured on `SuspendingClock`, which does not advance while the host sleeps. `Date()`
/// differences do, and once recorded a 6,635 s cell when the machine slept mid-run. `caffeinate` prevents sleep;
/// this keeps a missed one from silently inflating a duration.
public enum Elapsed {
    public static func seconds(_ d: Duration) -> Double {
        let (s, atto) = d.components
        return ((Double(s) + Double(atto) / 1e18) * 10).rounded() / 10
    }
}
