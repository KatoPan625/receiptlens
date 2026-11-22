import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "autoscaler"))
from autoscale import desired_replicas  # noqa: E402

ARGS = dict(target_rps=25, lo=1, hi=4, cooldown=60)


def test_scales_up_immediately_to_needed_count():
    assert desired_replicas(80, 1, below_since=None, now=0, **ARGS) == (4, None)  # ceil(80/25)=4


def test_never_exceeds_max_or_goes_below_min():
    assert desired_replicas(10_000, 2, below_since=None, now=0, **ARGS)[0] == 4
    assert desired_replicas(0, 1, below_since=None, now=0, **ARGS)[0] == 1


def test_scale_down_waits_for_cooldown():
    want, since = desired_replicas(5, 3, below_since=None, now=100, **ARGS)
    assert (want, since) == (3, 100)          # low load starts the clock
    assert desired_replicas(5, 3, below_since=since, now=130, **ARGS) == (3, 100)
    assert desired_replicas(5, 3, below_since=since, now=160, **ARGS) == (2, None)  # one step down


def test_load_spike_resets_scale_down_clock():
    assert desired_replicas(60, 2, below_since=100, now=150, **ARGS) == (3, None)


def test_no_scale_down_without_headroom():
    # 22.5 rps on 2 replicas: one replica (25 rps) would run at 90% -> keep 2, don't start the clock
    assert desired_replicas(22.5, 2, below_since=0, now=1000, **ARGS) == (2, None)
    # 15 rps: one replica at 60% -> eligible, clock starts
    assert desired_replicas(15, 2, below_since=None, now=1000, **ARGS) == (2, 1000)


def test_steady_load_keeps_count():
    assert desired_replicas(40, 2, below_since=None, now=0, **ARGS) == (2, None)  # ceil(40/25)=2
