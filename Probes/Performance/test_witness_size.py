"""Focused unit and negative controls for linker-map __TEXT,__text witness accounting."""

import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/check-witness-size.py"
SPEC = importlib.util.spec_from_file_location("check_witness_size", SCRIPT)
MOD = importlib.util.module_from_spec(SPEC)
assert SPEC is not None and SPEC.loader is not None
SPEC.loader.exec_module(MOD)

SAMPLE_LINK_MAP = """# Path: /tmp/WitnessSize
# Arch: arm64
# Object files:
[  0] linker synthesized
# Sections:
# Address\tSize\t\tSegment\tSection
0x100001000\t0x00000200\t__TEXT\t__text
0x100001200\t0x00000020\t__TEXT\t__stubs
# Symbols:
# Address\tSize\t\tFile  Name
0x100001000\t0x00000080\t[  1] _$s_doc_wcp
0x100001000\t0x00000080\t[  1] _$s_doc_wtk
0x100001080\t0x00000040\t[  1] _$s_doc_outlined
0x1000010C0\t0x00000040\t[  1] _$s_doc_func
0x100001100\t0x00000060\t[  1] _$s_other_wca
# Dead Stripped Symbols:
#           Size\t\tFile  Name
<<dead>>\t0x00000400\t[  1] _$s_doc_dead_wcp
"""

SAMPLE_SIZE_M = """Segment __TEXT: 16384
\tSection __text: 512
\tSection __stubs: 32
"""

DEMANGLE_TABLE = {
    "_$s_doc_wcp": "initializeWithCopy value witness for StateMachineWitnessSize.DocumentSyncFlow.Snapshot",
    "_$s_doc_wtk": "initializeWithTake value witness for StateMachineWitnessSize.DocumentSyncFlow.Snapshot",
    "_$s_doc_outlined": "outlined copy of StateMachineWitnessSize.DocumentSyncFlow.Snapshot",
    "_$s_doc_func": "StateMachineWitnessSize.DocumentSyncFlow.Local.send() -> ()",
    "_$s_other_wca": "assignWithCopy value witness for StateMachine.RuntimeState",
    "_$s_doc_dead_wcp": "initializeWithCopy value witness for StateMachineWitnessSize.DocumentSyncFlow.Dead",
}


def fake_demangle(names):
    return [DEMANGLE_TABLE[n] for n in names]


class WitnessSizeTests(unittest.TestCase):
    def test_alias_deduplication_and_dead_strip_exclusion(self):
        res = MOD.parse_link_map(SAMPLE_LINK_MAP, SAMPLE_SIZE_M, file_bytes=99999, demangler=fake_demangle)
        self.assertEqual(res["liveTextBytes"], 512)
        self.assertEqual(res["machOFileBytes"], 99999)
        self.assertEqual(res["aliasedAddresses"], 1)
        # 0x80 aliased twice -> counted once (128 B); dead-stripped 0x400 excluded!
        self.assertEqual(res["schema"]["valueWitnessBytes"], 128)
        self.assertEqual(res["schema"]["outlinedHelperBytes"], 64)
        self.assertEqual(res["schema"]["combinedWitnessAndHelperBytes"], 192)
        self.assertEqual(res["schema"]["attributedTextBytes"], 256)
        self.assertEqual(res["allLiveText"]["combinedWitnessAndHelperBytes"], 288)

    def test_overlapping_extents_deduplicate_without_double_count(self):
        self.assertEqual(MOD.extent_bytes({0x100: 0x40, 0x120: 0x40, 0x200: 0x10}), 0x70)

    def test_fail_closed_on_section_mismatch_and_missing_attribution(self):
        bad_size = "Segment __TEXT: 16384\n\tSection __text: 999\n"
        with self.assertRaisesRegex(ValueError, "mismatch"):
            MOD.parse_link_map(SAMPLE_LINK_MAP, bad_size, file_bytes=4096, demangler=fake_demangle)

        no_schema_map = SAMPLE_LINK_MAP.replace("_$s_doc_wcp", "_$s_other_wca").replace("_$s_doc_wtk", "_$s_other_wca").replace("_$s_doc_outlined", "_$s_other_wca").replace("_$s_doc_func", "_$s_other_wca")
        with self.assertRaisesRegex(ValueError, "attribution"):
            MOD.parse_link_map(no_schema_map, SAMPLE_SIZE_M, file_bytes=4096, demangler=fake_demangle)

        with self.assertRaisesRegex(ValueError, "Arch"):
            MOD.parse_link_map("# Arch: x86_64\n", SAMPLE_SIZE_M, file_bytes=4096, demangler=fake_demangle)

    def test_dual_budget_rejects_namespace_escape_and_schema_breach(self):
        res = MOD.parse_link_map(SAMPLE_LINK_MAP, SAMPLE_SIZE_M, file_bytes=99999, demangler=fake_demangle)
        # schema combined = 192 B, allLiveText combined = 288 B
        ok = MOD.evaluate_budgets(res, schema_budget=256, all_budget=512)
        self.assertTrue(ok["passed"])
        self.assertEqual(ok["failures"], [])

        schema_breach = MOD.evaluate_budgets(res, schema_budget=160, all_budget=512)
        self.assertFalse(schema_breach["passed"])
        self.assertFalse(schema_breach["schemaBudgetPassed"])
        self.assertTrue(schema_breach["allWitnessBudgetPassed"])

        # Simulates moving witnesses out of the schema namespace: schema passes, whole-executable cap fails.
        escaped = MOD.evaluate_budgets(res, schema_budget=256, all_budget=250)
        self.assertFalse(escaped["passed"])
        self.assertTrue(escaped["schemaBudgetPassed"])
        self.assertFalse(escaped["allWitnessBudgetPassed"])

    def test_paired_interleaved_summary(self):
        rounds = [
            {"baseline": {"transitionsPerSecond": 1000.0}, "candidate": {"transitionsPerSecond": 1040.0}, "candidateOverBaselineThroughputRatio": 1.04},
            {"baseline": {"transitionsPerSecond": 1010.0}, "candidate": {"transitionsPerSecond": 1010.0}, "candidateOverBaselineThroughputRatio": 1.00},
            {"baseline": {"transitionsPerSecond": 990.0}, "candidate": {"transitionsPerSecond": 1069.2}, "candidateOverBaselineThroughputRatio": 1.08},
        ]
        summary = MOD.summarize_paired(rounds)
        self.assertEqual(summary["rounds"], 3)
        self.assertAlmostEqual(summary["candidateOverBaselineThroughputRatio"]["median"], 1.04)
        self.assertAlmostEqual(summary["candidateOverBaselineThroughputRatio"]["mad"], 0.04)


if __name__ == "__main__":
    unittest.main()
