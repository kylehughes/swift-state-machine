#!/usr/bin/env python3
"""Aggregate the schedule explorer's interruption matrix coverage into the tables of Tests/ScheduleExplorer.md.

A run of the explorer with `EXPLORER_COVERAGE=PATH` writes every matrix cell its armed callbacks reached, one
`class|form|site|interrupt|phase|attempt|registration|origin` line each. A cell is recorded only when the armed event
changed what the presentation or its registrations hold, and its phase, form, attempt (`current` or `earlier`) and
registration state are those of the observation the callback concerns, read when the callback starts; `origin` is the
top-level event it ran under. This script reads one or more such files, sets the reached cells against the cells that
apply to each presentation class, and prints, in Markdown, each class's reached count and its site by phase table, the
registration states and origins each phase was reached in, the applicable cells it did not reach, and the cells that
do not apply, grouped by reason. The tables join the attempts, registration states and origins of the cells in each
phase; `--cells PATH` also writes every distinct reached cell with all eight coordinates, one per line, so that no
combination is lost to that join. Run the `matrix` family for each class, each into a file of its own, then aggregate
them:

    mkdir -p /tmp/state-machine-coverage
    for kind in SnapshotObservableObject SnapshotPresentation StateMachineObservableObject StateMachinePresentation; do
        EXPLORER_SMOKE=0 EXPLORER_FULL=1 EXPLORER_SLICES=matrix:4 EXPLORER_KIND=$kind \\
            EXPLORER_COVERAGE=/tmp/state-machine-coverage/$kind.txt \\
            swift test --build-system native --scratch-path /tmp/state-machine-explorer --filter ExplorerTests/full
    done
    python3 Scripts/explorer-coverage.py /tmp/state-machine-coverage/*.txt

The applicability rules below restate the "Not applicable, by reason" table of Tests/ScheduleExplorer.md; a change to
the matrix's forms, sites, interrupts or phases updates them, the explorer, and that document together.
"""
import argparse
import collections
from pathlib import Path

PHASES = ['registering', 'steady', 'ending']
COMBINE_SITES = ['subscriptionBefore', 'value', 'completion']
PASSIVE_FORMS = ['shared host', 'MainActor host', 'isolated host', 'async closure', 'sequence']
PASSIVE_SITES = ['change', 'report', 'hostSubscribe', 'hostRead', 'onCancel', 'destroy']
PASSIVE_INTERRUPTS = ['stop', 'drop on main', 'drop off main', 'observe again', 'replace']
DRIVING_SITES = ['change', 'report', 'hostSubscribe', 'hostRead', 'hostSend', 'hostClose', 'onCancel', 'destroy']
DRIVING_INTERRUPTS = ['stop', 'close', 'drop on main', 'drop off main', 'resume']

# Each class's forms, armable sites, and interrupting events, as `ExplorerMatrix.swift` names them in its cells.
CLASSES = {
    'SnapshotObservableObject': (PASSIVE_FORMS, PASSIVE_SITES + COMBINE_SITES, PASSIVE_INTERRUPTS),
    'SnapshotPresentation': (PASSIVE_FORMS, PASSIVE_SITES, PASSIVE_INTERRUPTS),
    'StateMachineObservableObject': (['driving'], DRIVING_SITES + COMBINE_SITES, DRIVING_INTERRUPTS),
    'StateMachinePresentation': (['driving'], DRIVING_SITES, DRIVING_INTERRUPTS),
}


def not_applicable(kind, form, site, interrupt, phase):
    """The reason no sequence can reach a cell, or `None` when the cell applies."""
    driving = form == 'driving'
    if site == 'completion':
        return ("A subscriber's completion runs only after the presentation is deallocated, so an armed event there "
                'acts on nothing (reached cells are counted apart as vacuous).')
    if site == 'subscriptionBefore' and phase != 'steady':
        return ('A subscription is handed out only by an attach, a steady-state event (an attach armed inside a '
                "registration's callback needs two arms: `chains`).")
    if site == 'onCancel' and phase != 'ending':
        return ('A token\'s cancellation runs only for a registration that is ending, so its callback concerns an '
                'ending observation whatever top-level event runs it.')
    if site == 'hostSubscribe' and phase != 'registering':
        return 'A registration call runs only while registering.'
    if site == 'hostSubscribe' and form == 'sequence':
        return 'The client registers the sequence before handing it over; no presentation call is in progress.'
    synchronous = form in ('MainActor host', 'isolated host') or driving
    if synchronous and site == 'report' and phase == 'steady':
        return ('A callback host ends a registration synchronously inside the ending event, so no report is left for '
                "a later steady-state turn (a shared host's cancellation can return on one).")
    if driving:
        if site == 'hostRead':
            return ('A driving presentation reads its host only at creation and in `commit`; the fake has no '
                    'proposals (the real-owner slice covers commit).')
        if site == 'hostSend' and phase != 'steady':
            return '`send` is a steady-state event.'
        if site == 'hostClose' and phase != 'ending':
            return '`close` is an ending.'
        return None
    if site == 'hostRead' and not (form == 'shared host' and phase == 'registering'):
        return "A passive presentation reads a host's snapshot only after registering with a shared host."
    if synchronous and site == 'destroy' and phase == 'ending':
        return ('An ending with a callback host destroys no client value inside the call: the shown snapshot stays, '
                "and the registration's callbacks go on a later turn.")
    if site == 'value' and phase == 'ending':
        return 'An ending publishes no new snapshot in a passive presentation.'
    if kind == 'SnapshotPresentation' and site == 'change' and phase == 'ending':
        return ('The Observation class tracks `snapshot`, which an ending does not change; its `isObserving` is the '
                'report site.')
    return None


def read_cells(paths):
    """The reached cells, `(class, form, site, interrupt, phase)`, and each one's details `(attempt, registration,
    origin)`."""
    cells, details = set(), collections.defaultdict(set)
    for path in paths:
        for line in path.read_text().splitlines():
            line = line.strip()
            if line:
                fields = tuple(line.split('|'))
                if len(fields) != 8:
                    raise SystemExit(f'{path}: not a `class|form|site|interrupt|phase|attempt|registration|origin` cell: {line}')
                cells.add(fields[:5])
                details[fields[:5]].add(fields[5:])
    return cells, details


def report(cells, details=None):
    details = details or {}
    lines = []
    reasons = collections.Counter()
    for kind, (forms, sites, interrupts) in CLASSES.items():
        every = {(kind, f, s, i, p) for f in forms for s in sites for i in interrupts for p in PHASES}
        applicable = set()
        for cell in every:
            reason = not_applicable(*cell)
            if reason is None:
                applicable.add(cell)
            else:
                reasons[(kind, reason)] += 1
        reached = {cell for cell in cells if cell[0] == kind}
        inside = reached & applicable
        outside = len(reached - applicable)
        outside_text = f'{outside} reached cells' if outside else 'no reached cells'
        lines += [f'#### {kind}', '',
                  f'{len(inside)} of {len(applicable)} applicable cells reached; {len(every) - len(applicable)} not '
                  f'applicable; {outside_text} outside the applicable set.', '',
                  '| site | ' + ' | '.join(PHASES) + ' |', '|---|' + '---|' * len(PHASES)]
        for site in sites:
            row = []
            for phase in PHASES:
                count = sum(1 for cell in inside if cell[2] == site and cell[4] == phase)
                total = sum(1 for cell in applicable if cell[2] == site and cell[4] == phase)
                row.append(f'{count}/{total}' if total else 'n/a')
            lines.append(f'| {site} | ' + ' | '.join(row) + ' |')
        lines += ['', '| phase | attempts | registration states | origins |', '|---|---|---|---|']
        for phase in PHASES:
            seen = set().union(*[details.get(cell, set()) for cell in inside if cell[4] == phase] or [set()])
            column = lambda index: ', '.join(sorted({entry[index] for entry in seen})) or '-'
            lines.append(f'| {phase} | {column(0)} | {column(1)} | {column(2)} |')
        missing = collections.defaultdict(list)
        for cell in sorted(applicable - inside):
            missing[(cell[2], cell[4])].append(f'{cell[1]}: {cell[3]}')
        if missing:
            lines += ['', f'Applicable cells not reached ({len(applicable - inside)}):', '']
            lines += [f'- {site}, {phase}: ' + ', '.join(entries) for (site, phase), entries in sorted(missing.items())]
        lines.append('')
    lines += ['#### Not applicable, by reason', '', '| Class | Cells | Reason |', '|---|---|---|']
    # By class, then by reason as a sentence's lowercase start reads.
    order = sorted(reasons.items(), key=lambda item: (item[0][0], item[0][1][0].lower() + item[0][1][1:]))
    lines += [f'| {kind} | {count} | {reason} |' for (kind, reason), count in order]
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('coverage', type=Path, nargs='+', help='Files that EXPLORER_COVERAGE runs wrote')
    parser.add_argument('--output', type=Path, help='Write the Markdown here instead of to standard output')
    parser.add_argument('--cells', type=Path, help='Also write every distinct reached cell, all eight coordinates')
    args = parser.parse_args()
    cells, details = read_cells(args.coverage)
    text = report(cells, details)
    if args.cells:
        full = sorted('|'.join(cell + entry) for cell in cells for entry in details.get(cell, set()))
        args.cells.write_text(''.join(line + '\n' for line in full))

    if args.output:
        args.output.write_text(text)
    else:
        print(text, end='')


if __name__ == '__main__':
    main()
