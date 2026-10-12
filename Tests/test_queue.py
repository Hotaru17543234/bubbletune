import random
from queue_model import PlayQueue

ids = ['A', 'B', 'C', 'D', 'E']


def play_n(q, n, automatic=True, repeat='all'):
    out = []
    for _ in range(n):
        s = q.next(automatic, repeat)
        out.append((s.id, s.autoplay))
    return out


# 1. sequential from A, list loop
q = PlayQueue('sequential'); q.rebuild(ids, 'A')
r = play_n(q, 6)
assert [x for x, _ in r] == ['B', 'C', 'D', 'E', 'A', 'B'], r
assert all(a for _, a in r)

# 2. reverse from E goes E->D->...->A then wraps to E
q = PlayQueue('reverse'); q.rebuild(ids, 'E')
r = play_n(q, 5)
assert [x for x, _ in r] == ['D', 'C', 'B', 'A', 'E'], r

# 3. reverse started from C (tapped C in list)
q = PlayQueue('reverse'); q.rebuild(ids, None); q.select('C', ids)
assert [x for x, _ in play_n(q, 3)] == ['B', 'A', 'E']

# 4. repeat off: at the end, stop on the first song of the order (autoplay False)
q = PlayQueue('sequential'); q.rebuild(ids, 'D')
r = play_n(q, 2, repeat='off')
assert r == [('E', True), ('A', False)], r
# manual next at the end with repeat off still wraps and plays
q = PlayQueue('sequential'); q.rebuild(ids, 'E')
s = q.next(False, 'off'); assert (s.id, s.autoplay) == ('A', True)

# 5. repeat one: automatic finish replays; manual next moves on
q = PlayQueue('sequential'); q.rebuild(ids, 'B')
s = q.next(True, 'one'); assert s.id == 'B'
s = q.next(False, 'one'); assert s.id == 'C'

# 6. shuffle: each cycle plays every song exactly once, never the same song twice in a row
for seed in range(300):
    q = PlayQueue('shuffle', random.Random(seed)); q.rebuild(ids, 'C')
    seq = ['C'] + [x for x, _ in play_n(q, 4 * len(ids) - 1)]
    for k in range(0, len(seq), len(ids)):
        cyc = seq[k:k + len(ids)]
        assert sorted(cyc) == sorted(ids), (seed, seq)
    for a, b in zip(seq, seq[1:]):
        assert a != b, (seed, seq)

# 7. previous wraps backwards
q = PlayQueue('sequential'); q.rebuild(ids, 'A')
assert q.previous() == 'E'
assert q.previous() == 'D'
q = PlayQueue('reverse'); q.rebuild(ids, 'A')
assert q.previous() == 'B'  # in reverse order the song before A is B

# 8. switching mode keeps the current song
q = PlayQueue('sequential'); q.rebuild(ids, 'C')
q.set_mode('reverse', ids); assert q.current == 'C'
assert q.next(True, 'all').id == 'B'
q.set_mode('shuffle', ids); assert q.current == 'B' and q.order[0] == 'B'
q.set_mode('sequential', ids); assert q.next(True, 'all').id == 'C'

# 9. library sync: delete other songs, add new ones, reorder
q = PlayQueue('sequential'); q.rebuild(ids, 'C')
q.sync(['A', 'C', 'E', 'F']); assert q.current == 'C' and q.next(True, 'all').id == 'E'
q.sync(['F', 'E', 'A']); assert q.current == 'E' and q.next(True, 'all').id == 'A'
# current deleted -> current cleared
q.sync(['F', 'E']); assert q.current is None
# with no current, next starts at the beginning
assert q.next(True, 'all').id == 'F'

# 10. shuffle sync: new songs land after the current song, kept order otherwise preserved
for seed in range(200):
    q = PlayQueue('shuffle', random.Random(seed)); q.rebuild(ids, 'A')
    q.next(True, 'all'); q.next(True, 'all')
    cur = q.current
    before = list(q.order)
    q.sync(ids + ['X', 'Y'])
    pos = q.order.index(cur)
    assert 'X' in q.order[pos + 1:] and 'Y' in q.order[pos + 1:], (seed, q.order)
    assert [i for i in q.order if i in before] == before
    q.sync([i for i in ids + ['X', 'Y'] if i != 'B'])
    assert 'B' not in q.order

# 11. empty library
q = PlayQueue('shuffle'); q.rebuild([], None)
assert q.next(True, 'all') is None and q.previous() is None and q.start() is None

# 12. single song: shuffle wrap must not crash, repeat all replays it
q = PlayQueue('shuffle'); q.rebuild(['Z'], 'Z')
assert q.next(True, 'all').id == 'Z'
assert q.next(True, 'off').autoplay is False

# 13. start() with nothing selected picks the first song of the order
q = PlayQueue('reverse'); q.rebuild(ids, None)
assert q.start() == 'E'

print('all queue tests passed')
