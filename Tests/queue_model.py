"""Python mirror of PlayQueue.swift, used only to test the play-order logic."""
import random


class Step:
    def __init__(self, id, autoplay):
        self.id = id
        self.autoplay = autoplay

    def __repr__(self):
        return f"Step({self.id}, {self.autoplay})"


class PlayQueue:
    def __init__(self, mode, rng=None):
        self.mode = mode          # 'sequential' | 'reverse' | 'shuffle'
        self.order = []
        self.current = None
        self.rng = rng or random.Random()

    def position(self):
        if self.current is None:
            return None
        try:
            return self.order.index(self.current)
        except ValueError:
            return None

    def rebuild(self, ids, start):
        self.current = start if (start is not None and start in ids) else None
        if self.mode == 'sequential':
            self.order = list(ids)
        elif self.mode == 'reverse':
            self.order = list(reversed(ids))
        else:
            rest = [i for i in ids if i != self.current]
            self.rng.shuffle(rest)
            self.order = ([self.current] if self.current is not None else []) + rest

    def set_mode(self, mode, ids):
        self.mode = mode
        self.rebuild(ids, self.current)

    def sync(self, ids):
        idset = set(ids)
        if self.current is not None and self.current not in idset:
            self.current = None
        if self.mode == 'sequential':
            self.order = list(ids)
        elif self.mode == 'reverse':
            self.order = list(reversed(ids))
        else:
            kept = [i for i in self.order if i in idset]
            keptset = set(kept)
            new = [i for i in ids if i not in keptset]
            start = (kept.index(self.current) + 1) if self.current in keptset else 0
            for i in new:
                pos = self.rng.randint(start, len(kept))
                kept.insert(pos, i)
            self.order = kept

    def select(self, id, ids):
        if self.mode == 'shuffle':
            self.rebuild(ids, id)
        else:
            self.current = id

    def start(self):
        if not self.order:
            return None
        if self.current is None:
            self.current = self.order[0]
        return self.current

    def reshuffle(self, avoid_first):
        self.rng.shuffle(self.order)
        if len(self.order) > 1 and self.order[0] == avoid_first:
            j = self.rng.randint(1, len(self.order) - 1)
            self.order[0], self.order[j] = self.order[j], self.order[0]

    def next(self, automatic, repeat):
        if not self.order:
            return None
        pos = self.position()
        if pos is None:
            self.current = self.order[0]
            return Step(self.current, True)
        if automatic and repeat == 'one':
            return Step(self.current, True)
        if pos + 1 < len(self.order):
            self.current = self.order[pos + 1]
            return Step(self.current, True)
        # reached the end of the order
        if self.mode == 'shuffle':
            self.reshuffle(self.current)
        self.current = self.order[0]
        return Step(self.current, not (automatic and repeat == 'off'))

    def previous(self):
        if not self.order:
            return None
        pos = self.position()
        if pos is None:
            self.current = self.order[-1]
            return self.current
        self.current = self.order[pos - 1] if pos > 0 else self.order[-1]
        return self.current
