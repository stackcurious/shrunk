import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from hit_rate import collapse_runs, verdict  # noqa: E402


def obs(quantity, observed_at, source="fdc", unit_kind="mass"):
    return {"quantity": quantity, "observed_at": observed_at, "source": source, "unit_kind": unit_kind}


class TestCollapseRuns:
    def test_a_confirmation_joins_the_run_it_confirms(self):
        runs = collapse_runs([obs(500, 10, "curated"), obs(450, 20, "curated"), obs(450, 30, "fdc")])
        assert [r["quantity"] for r in runs] == [500, 450]
        assert runs[1]["sources"] == ["curated", "fdc"]
        assert runs[1]["opened_at"] == 20
        assert runs[1]["observed_at"] == 30

    def test_three_runs_stay_three(self):
        runs = collapse_runs([obs(500, 10), obs(450, 20), obs(450, 30), obs(400, 40)])
        assert [r["quantity"] for r in runs] == [500, 450, 400]

    def test_noise_inside_the_tolerance_is_one_run(self):
        runs = collapse_runs([obs(450, 10), obs(452, 20), obs(450, 30)])
        assert len(runs) == 1
        assert runs[0]["quantity"] == 450

    def test_drift_cannot_accumulate(self):
        # Every step is under 1% of its predecessor, but 450 -> 458 is not.
        runs = collapse_runs([obs(450, 10), obs(454, 20), obs(458, 30)])
        assert [r["quantity"] for r in runs] == [450, 458]

    def test_a_zero_never_absorbs_a_real_size(self):
        assert [r["quantity"] for r in collapse_runs([obs(0, 10), obs(28, 20)])] == [0, 28]

    def test_empty(self):
        assert collapse_runs([]) == []


class TestVerdict:
    def test_a_confirming_observation_does_not_erase_the_shrink(self):
        # The Fage case: USDA confirms both endpoints and the entry used to
        # score "no shrink (+0.0%)" because the last two observations were
        # the curated 32 oz row and the USDA 32 oz row.
        v = verdict([obs(1000.6, 10, "curated"), obs(907.185, 20, "curated"), obs(907.185, 30, "fdc")])
        assert v.startswith("shrink"), v
        assert "-9.3%" in v

    def test_three_runs_compare_the_last_two(self):
        v = verdict([obs(500, 10), obs(450, 20), obs(450, 30), obs(400, 40)])
        assert v == "shrink -11.1%"

    def test_one_run_is_not_a_verdict(self):
        assert verdict([obs(450, 10), obs(452, 20), obs(450, 30)]) == "1 size on record"

    def test_a_growth_is_still_reported_as_no_shrink(self):
        assert verdict([obs(400, 10), obs(500, 20)]) == "no shrink (+25.0%)"

    def test_kinds_are_never_compared(self):
        v = verdict([
            obs(1000, 10, unit_kind="mass"),
            obs(900, 20, unit_kind="mass"),
            obs(900, 30, unit_kind="volume"),
        ])
        assert v == "1 size on record"

    def test_no_history(self):
        assert verdict([]) == "no history"
