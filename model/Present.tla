---------------------------- MODULE Present ----------------------------
(***************************************************************************)
(* The direct present of the QEMU window: the guest's scanout IOSurface    *)
(* goes on the layer through the vsync queue.                              *)
(*                                                                         *)
(* Promise: once QEMU has nothing left to do for the window (no flush to   *)
(* present, no frame in flight or queued, no present_bh), the layer shows  *)
(* the buffer the guest flushed last, as the present would send it now.    *)
(* Otherwise the window stays a frame behind until the guest draws again.  *)
(*                                                                         *)
(* Covers app/runtime/patches/omacvm-cocoa-present-direct.patch            *)
(* (cocoa_gl_present's same-buffer rule, cocoa_gl_present_send,            *)
(* present_frame_skip's direct frames), omacvm-cocoa-present-tiles.patch   *)
(* (present_frame_skip, present_frame_absorb, present_pend,                *)
(* cocoa_gl_present_bh), qemu-cocoa-gl-present-vsync.patch and             *)
(* qemu-cocoa-gl-present-trim.patch (cocoa_gl_present_queue_frame,         *)
(* cocoa_gl_present_vsync).                                                *)
(*                                                                         *)
(* Abstractions: every frame is a direct frame (the guest's buffers are    *)
(* IOSurfaces): drawn frames and their tiles are out, so a skipped frame   *)
(* never has a tile frame after it. "how" is the present's filter and HDR  *)
(* (present_direct_last_how). Each action is one locked step of the code;  *)
(* which skips a tick or a queued frame makes (merge, full queue, input    *)
(* first, the quarter-second trim, the once-a-second drop) is free, as     *)
(* their timing rules are left out. The window is in sight, vsync on.      *)
(* "use" is QEMU's own use count; Core Animation's use of the buffer on    *)
(* the layer is the "shown" half of the same-buffer rule.                  *)
(*                                                                         *)
(* Last matched these patches at #49 (1d3250f5).                           *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Bufs,           \* the guest's IOSurfaces
    None,           \* no buffer
    QMax,           \* PRESENT_QUEUE
    MaxHowChanges,  \* filter or HDR changes in a run
    Fix             \* present_frame_skip gives a direct frame back at once (#49)

Hows == {0, 1}
Frame(b, h) == [buf |-> b, how |-> h]
NoFrame == Frame(None, 0)

VARIABLES
    tiles,      \* present_tiles_on > 0 ("Draw only what changed"), fixed for a run
    guest,      \* the buffer the guest's scanout shows (flushed last)
    how,        \* how the present would send it now
    dirty,      \* gl_dirty
    bh,         \* present_bh scheduled
    last,       \* present_direct_last
    lastHow,    \* present_direct_last_how
    use,        \* QEMU's IOSurfaceIncrementUseCount per buffer
    inflight,   \* sent, waiting for the guest's fence on present_queue
    queue,      \* present_sync.queue
    pend,       \* present_pend
    shown,      \* present_shown: the buffer on the layer
    shownHow,   \* how it went on the layer
    howChanges,
    stopped     \* the guest draws no more

vars == <<tiles, guest, how, dirty, bh, last, lastHow, use, inflight, queue,
          pend, shown, shownHow, howChanges, stopped>>

Dec(u, b) == [u EXCEPT ![b] = @ - 1]

(* present_frame_skip(older, next) with present_frame_absorb: [use, pend] after it *)
Skip(u, p, older, hasNext) ==
    IF ~tiles \/ Fix THEN [use |-> Dec(u, older.buf), pend |-> p]
    \* absorb(next, older): a whole next frame lets OLDER go
    ELSE IF hasNext THEN [use |-> Dec(u, older.buf), pend |-> p]
    \* absorb(older, &present_pend) lets the old one go; OLDER waits there
    ELSE [use |-> IF p = NoFrame THEN u ELSE Dec(u, p.buf), pend |-> older]

TypeOK ==
    /\ tiles \in BOOLEAN
    /\ guest \in Bufs /\ how \in Hows
    /\ dirty \in BOOLEAN /\ bh \in BOOLEAN
    /\ last \in Bufs \cup {None} /\ lastHow \in Hows
    /\ use \in [Bufs -> Nat]
    /\ Len(queue) <= QMax
    /\ shown \in Bufs \cup {None} /\ shownHow \in Hows

Init ==
    /\ tiles \in BOOLEAN
    /\ guest \in Bufs
    /\ how = 0
    /\ dirty = TRUE
    /\ bh = FALSE
    /\ last = None
    /\ lastHow = 0
    /\ use = [b \in Bufs |-> 0]
    /\ inflight = <<>>
    /\ queue = <<>>
    /\ pend = NoFrame
    /\ shown = None
    /\ shownHow = 0
    /\ howChanges = 0
    /\ stopped = FALSE

(* The guest draws into B and flushes it (virgl_cmd_resource_flush). A write into a *)
(* buffer in use or on the layer goes to another IOSurface (virgl-scanout-iosurface). *)
Write(b) ==
    /\ ~stopped
    /\ use[b] = 0 /\ b # shown
    /\ guest' = b
    /\ dirty' = TRUE
    /\ UNCHANGED <<tiles, how, bh, last, lastHow, use, inflight, queue, pend,
                   shown, shownHow, howChanges, stopped>>

(* The guest flushes its buffer again with nothing written. *)
Reflush ==
    /\ ~stopped
    /\ dirty' = TRUE
    /\ UNCHANGED <<tiles, guest, how, bh, last, lastHow, use, inflight, queue,
                   pend, shown, shownHow, howChanges, stopped>>

(* Zoom interpolation or HDR changes: the window is drawn again. *)
ChangeHow ==
    /\ ~stopped
    /\ howChanges < MaxHowChanges
    /\ how' = 1 - how
    /\ howChanges' = howChanges + 1
    /\ dirty' = TRUE
    /\ UNCHANGED <<tiles, guest, bh, last, lastHow, use, inflight, queue, pend,
                   shown, shownHow, stopped>>

Stop ==
    /\ ~stopped
    /\ stopped' = TRUE
    /\ UNCHANGED <<tiles, guest, how, dirty, bh, last, lastHow, use, inflight,
                   queue, pend, shown, shownHow, howChanges>>

(* cocoa_gl_present: PD_SAME, or PD_DIRECT through cocoa_gl_present_direct and *)
(* cocoa_gl_present_send (CFRetain, IOSurfaceIncrementUseCount). *)
Present ==
    /\ dirty
    /\ dirty' = FALSE
    /\ IF guest = last /\ how = lastHow /\ (guest = shown \/ use[guest] > 0)
       THEN UNCHANGED <<last, lastHow, use, inflight>>
       ELSE /\ last' = guest
            /\ lastHow' = how
            /\ use' = [use EXCEPT ![guest] = @ + 1]
            /\ inflight' = Append(inflight, Frame(guest, how))
    /\ UNCHANGED <<tiles, guest, how, bh, queue, pend, shown, shownHow,
                   howChanges, stopped>>

(* cocoa_gl_present_queue_frame after the fence wait: present_pend goes into F *)
(* (a whole frame lets it go); unlinked, F is shown at once (the vsync tick *)
(* unlinks only with nothing queued or in flight, and an unlinked present queues *)
(* nothing); else a merge or a full queue skips a frame before F, which comes *)
(* after it. *)
QueueFrame ==
    /\ inflight # <<>>
    /\ LET f == Head(inflight)
           u1 == IF pend = NoFrame THEN use ELSE Dec(use, pend.buf)
       IN /\ inflight' = Tail(inflight)
          /\ \/ /\ queue = <<>>
                /\ shown' = f.buf
                /\ shownHow' = f.how
                /\ use' = Dec(u1, f.buf)
                /\ pend' = NoFrame
                /\ UNCHANGED queue
             \/ /\ queue # <<>>
                /\ LET s == Skip(u1, NoFrame, queue[Len(queue)], TRUE)
                   IN /\ use' = s.use
                      /\ pend' = s.pend
                /\ queue' = Append(SubSeq(queue, 1, Len(queue) - 1), f)
                /\ UNCHANGED <<shown, shownHow>>
             \/ /\ IF Len(queue) = QMax
                   THEN LET s == Skip(u1, NoFrame, Head(queue), TRUE)
                        IN /\ use' = s.use
                           /\ pend' = s.pend
                           /\ queue' = Append(Tail(queue), f)
                   ELSE /\ use' = u1
                        /\ pend' = NoFrame
                        /\ queue' = Append(queue, f)
                /\ UNCHANGED <<shown, shownHow>>
    /\ UNCHANGED <<tiles, guest, how, dirty, bh, last, lastHow, howChanges, stopped>>

(* cocoa_gl_present_vsync: input first skips all but the newest; the head goes on *)
(* the layer; the trims may skip the frame left after it, up to twice; a shown *)
(* frame schedules present_bh. *)
Tick ==
    /\ queue # <<>>
    /\ \E input \in BOOLEAN, trims \in 0..2:
        LET q0 == IF input /\ Len(queue) > 1 THEN SubSeq(queue, Len(queue), Len(queue)) ELSE queue
            u0 == IF input /\ Len(queue) > 1
                  THEN [b \in Bufs |-> use[b] - Cardinality({i \in 1..(Len(queue) - 1) : queue[i].buf = b})]
                  ELSE use
            s == Head(q0)
            q1 == Tail(q0)
            u1 == Dec(u0, s.buf)
            t1 == IF trims >= 1 /\ q1 # <<>> THEN Skip(u1, pend, Head(q1), Len(q1) > 1) ELSE [use |-> u1, pend |-> pend]
            q2 == IF trims >= 1 /\ q1 # <<>> THEN Tail(q1) ELSE q1
            t2 == IF trims >= 2 /\ q2 # <<>> THEN Skip(t1.use, t1.pend, Head(q2), Len(q2) > 1) ELSE t1
            q3 == IF trims >= 2 /\ q2 # <<>> THEN Tail(q2) ELSE q2
        IN /\ shown' = s.buf
           /\ shownHow' = s.how
           /\ queue' = q3
           /\ use' = t2.use
           /\ pend' = t2.pend
           /\ bh' = TRUE
    /\ UNCHANGED <<tiles, guest, how, dirty, last, lastHow, inflight, howChanges, stopped>>

(* cocoa_gl_present_bh: every direct frame sets present_tiles_full, so the bh *)
(* asks for a present (only a drawn whole frame clears it). *)
Bh ==
    /\ bh
    /\ bh' = FALSE
    /\ dirty' = TRUE
    /\ UNCHANGED <<tiles, guest, how, last, lastHow, use, inflight, queue, pend,
                   shown, shownHow, howChanges, stopped>>

Qemu == Present \/ QueueFrame \/ Tick \/ Bh

Next ==
    \/ \E b \in Bufs : Write(b)
    \/ Reflush \/ ChangeHow \/ Stop
    \/ Qemu

Spec == Init /\ [][Next]_vars /\ WF_vars(Present) /\ WF_vars(QueueFrame)
                              /\ WF_vars(Tick) /\ WF_vars(Bh)

AtRest == ~dirty /\ ~bh /\ inflight = <<>> /\ queue = <<>>

(* Accepted: the buffer on the layer is the right one, but a filter or HDR change *)
(* went with a second frame of the same buffer, and the queue skipped that frame: *)
(* the layer keeps the old filter until the guest draws again, which heals it. It *)
(* needs a filter change during a trim and does nothing to the picture's content. *)
StaleHowOnly == shown = last /\ how = lastHow

Promise == AtRest => (shown = guest /\ (shownHow = how \/ StaleHowOnly))

(* Every use QEMU counts belongs to a frame that holds it, and none goes below 0. *)
Count(s, b) == Cardinality({i \in 1..Len(s) : s[i].buf = b})
UseHeld == \A b \in Bufs :
    use[b] = Count(inflight, b) + Count(queue, b) + (IF pend.buf = b THEN 1 ELSE 0)

(* Once the guest stops, QEMU's work for the window ends (the bh's retries too). *)
Settles == stopped ~> AtRest
=============================================================================
