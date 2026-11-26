# Per-identity token-bucket rate limiter.
#
# Keyed on the caller's hierarchical IDENTITY (the sensor's device_id), NOT on the
# source IP. This is the fix for the scalability finding in the evaluation: one node
# can host many sensors, so a per-IP limit at scale throttles a legitimate node (many
# identities behind one address) while a per-identity limit gives each sensor its own
# bucket and still sheds a flood that reuses a single identity.
#
# Default parameters (5 tokens/s, burst 10) match a well-behaved sensor (one reading
# every couple of seconds, i.e. < 1 req/s) with wide headroom, while a flood that
# reuses one identity drains its bucket in ~2 s and is then shed.
import threading
import time


class TokenBucketSet:
    def __init__(self, rate=5.0, burst=10.0):
        self.rate = float(rate)       # tokens refilled per second
        self.burst = float(burst)     # bucket capacity
        self._buckets = {}            # key -> (tokens, last_refill_monotonic)
        self._lock = threading.Lock()

    def allow(self, key):
        """Consume one token for `key`. Return True if allowed, False if shed."""
        now = time.monotonic()
        with self._lock:
            tokens, last = self._buckets.get(key, (self.burst, now))
            tokens = min(self.burst, tokens + (now - last) * self.rate)
            if tokens >= 1.0:
                self._buckets[key] = (tokens - 1.0, now)
                return True
            self._buckets[key] = (tokens, now)
            return False

    def tracked(self):
        with self._lock:
            return len(self._buckets)
