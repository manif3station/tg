package D2TG::Transcribe;

use strict;
use warnings;
use File::Temp qw(tempdir tempfile);
use File::Spec;
use File::Basename qw(fileparse);
use File::Path qw(remove_tree);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
use D2TG::Subprocess;
use D2TG::Poller;
use D2TG::Download;

our $TIMEOUT     = 300;
our $CURRENT_PID = undef;
our $FORKER      = sub { return fork() };

our @MODEL_TIERS = qw(medium small base);

# TGT-140: $TIMEOUT alone stayed flat even after select_model started
# tiering the model by duration - a clip picked as the fastest tier
# could still legitimately run past 300s at real per-host throughput
# (measured: medium ran at ~5.6x real time, so a 102.48s clip took
# 571s). _scaled_timeout turns the same duration signal select_model
# already computes into a per-attempt budget instead: proportional to
# duration with a safety multiplier well above the worst measured
# throughput, floored at $TIMEOUT itself (a Codex review finding: a
# hard-coded floor would silently ignore a caller-configured $TIMEOUT,
# so the floor is always whatever $TIMEOUT currently is, not a separate
# constant) and capped at a sane ceiling (never unbounded).
our $TIMEOUT_MULTIPLIER = 8;
our $TIMEOUT_CEILING    = 3600;

# TGT-179 (JOB-003 scheduled hourly bug hunt finding): _probe_duration's
# open('-|', 'ffprobe', ...) below had no timeout at all, unlike every
# sibling subprocess call in this codebase (whisper, gtts-cli/ffmpeg,
# HTTP downloads - all guarded by SIGALRM/_with_hard_timeout per
# TGT-035/044/126/127). It runs synchronously, before transcribe()'s
# own retry-loop timeout scoping even begins, so a hang here blocks the
# ENTIRE single-threaded poller indefinitely for every chat, not just
# the one triggering it - reproduced live via a stalled FIFO. A probe
# genuinely only reads one short line of ffprobe's own metadata output,
# so this is deliberately much shorter than $TIMEOUT itself.
our $PROBE_TIMEOUT = 10;

sub _scaled_timeout {
    my ($duration) = @_;

    # A Codex QA-stage review finding: capping at the fixed
    # $TIMEOUT_CEILING after flooring at $TIMEOUT could undercut a
    # caller-configured $TIMEOUT larger than the default ceiling (e.g.
    # $TIMEOUT=7200 would still be capped down to 3600) - the whole
    # point of flooring at $TIMEOUT is that the scaled budget is never
    # worse than it, so the ceiling itself must never go below it
    # either.
    my $ceiling = $TIMEOUT_CEILING > $TIMEOUT ? $TIMEOUT_CEILING : $TIMEOUT;

    my $t = ( $duration // 0 ) * $TIMEOUT_MULTIPLIER;
    $t = $TIMEOUT  if $t < $TIMEOUT;
    $t = $ceiling  if $t > $ceiling;
    return $t;
}

sub select_model {
    my ($duration) = @_;

    # TGT-251 (Michael, live via Telegram, 2026-09-15): "medium" measured
    # at ~5.6x real time on his host (TGT-100's own follow-up data, just
    # below) meant even a genuinely short clip paid minutes of wall time.
    # A definitively-parsed short duration now gets the fastest tier
    # straight away - but $parsed is tracked separately from the
    # coerced-to-0 duration below, so an unparsed/failed probe (duration
    # undef or non-numeric) is never swept into this new tier just
    # because 0 <= 60: it is an unknown duration, not a confirmed-short
    # one, and must keep falling back to 'medium' exactly as before
    # (t/74's own documented invariant - a probe failure never behaves
    # worse than pre-TGT-100 code did).
    my $parsed = defined $duration && $duration =~ /^\s*[\d.]+\s*$/;
    $duration = $parsed ? $duration : 0;

    return 'base'   if $parsed && $duration > 0 && $duration <= 60;
    return 'medium' if $duration <= 300;
    return 'small'  if $duration <= 900;
    return 'base';
}

sub _next_tier {
    my ($model) = @_;

    for my $i ( 0 .. $#MODEL_TIERS - 1 ) {
        return $MODEL_TIERS[ $i + 1 ] if $MODEL_TIERS[$i] eq $model;
    }
    return undef;
}

sub _probe_duration {
    my ($audio_path) = @_;

    # TGT-179 (JOB-003 scheduled hourly bug hunt finding): this used to
    # be a plain blocking open('-|', 'ffprobe', ...) with NO timeout at
    # all - unlike every sibling subprocess call in this codebase
    # (whisper/gtts-cli/ffmpeg/HTTP downloads, all guarded by SIGALRM
    # or a waitpid-poll timeout). It runs synchronously in transcribe()
    # before the retry loop's own timeout scoping even begins, so a
    # hang here blocked the ENTIRE single-threaded poller indefinitely
    # for every chat, not just the one triggering it - reproduced live
    # via a stalled FIFO. A plain alarm()-around-a-blocking-readline
    # does NOT reliably interrupt it either (PerlIO retries a buffered
    # read on EINTR without giving Perl a chance to run the deferred
    # SIGALRM handler mid-read) - the same waitpid(WNOHANG)-poll
    # pattern _run (below) already uses for whisper is what's actually
    # proven to interrupt reliably in this codebase, so this reuses it
    # via D2TG::Subprocess's own now-optional stdout-capture support,
    # rather than a third alarm-based implementation.
    my ( $out_fh, $out_path ) = tempfile( UNLINK => 1 );
    close $out_fh;

    my $pid = D2TG::Subprocess::fork_in_own_process_group(
        cmd    => [ 'ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', $audio_path ],
        stdout => $out_path,
    );

    my $deadline = time() + $PROBE_TIMEOUT;
    while (1) {
        my $reaped = waitpid( $pid, WNOHANG );
        last if $reaped == $pid;

        if ( time() >= $deadline ) {
            # Same group-then-direct-pid kill escalation _run already
            # uses below (TGT-128, hardened by a Codex review finding:
            # a signal straight to a pid can't be missed by a
            # process-group mismatch the way -$pid targeting can) - no
            # orphaned ffprobe process or process group is left behind
            # either way.
            kill( 'KILL', -$pid );
            kill( 'KILL', $pid );
            waitpid( $pid, 0 );
            last;
        }

        sleep(0.2);
    }

    my $duration;
    if ( open my $fh, '<', $out_path ) {
        $duration = <$fh>;
        close $fh;
    }

    # QA-stage Codex review finding: File::Temp's own UNLINK=>1 only
    # queues removal for Perl's own process exit, not for whenever this
    # function returns - in a long-running poller, every single probe
    # (potentially thousands over its lifetime) would leave its own
    # temp file sitting on disk until the poller process itself
    # eventually exits, and even that queued cleanup never runs at all
    # if the process is killed rather than exited normally. Explicit,
    # best-effort unlink here instead - failure to remove it is not
    # itself a reason to fail the probe (matches this function's own
    # policy of never letting probe-adjacent bookkeeping become fatal).
    unlink $out_path;

    # A failed/unparseable/timed-out probe (ffprobe missing, corrupt
    # audio, no output, or a hang killed above) deliberately falls back
    # to 0 seconds, i.e. select_model's 'medium' tier - the same model
    # transcribe() always used before this feature existed, so a probe
    # failure never behaves worse than pre-TGT-100 code did.
    return 0 unless defined $duration && $duration =~ /^\s*[\d.]+\s*$/;
    return $duration + 0;
}

sub transcribe {
    my ( $audio_path, %args ) = @_;

    my $duration_fn     = $args{duration_fn} || \&_probe_duration;
    my $explicit_model  = $args{model};

    # Duration is probed at most once, only for the automatic path -
    # explicit means explicit (same scope restriction as the
    # retry-on-timeout fallback below), and it's reused for both model
    # selection and the scaled timeout so they stay consistent with
    # each other across retries.
    my $duration = $explicit_model ? undef : $duration_fn->($audio_path);
    my $model    = $explicit_model || select_model($duration);
    die "D2TG::Transcribe::transcribe: model must not be an English-only (.en) checkpoint\n"
      if $model =~ /\.en$/;

    my $runner = $args{runner} || \&_run;

    while (1) {
        my $out_dir = tempdir( CLEANUP => 0 );

        my $text = eval {
            local $TIMEOUT = _scaled_timeout($duration) if defined $duration;
            if ( $runner->( 'whisper', $audio_path, '--model', $model, '--output_format', 'txt', '--output_dir', $out_dir ) != 0 ) {
                die "D2TG::Transcribe::transcribe: whisper failed to transcribe $audio_path\n";
            }

            my ($name) = fileparse( $audio_path, qr/\.[^.]*/ );
            my $txt_path = File::Spec->catfile( $out_dir, "$name.txt" );

            open my $fh, '<', $txt_path
              or die "D2TG::Transcribe::transcribe: whisper did not produce the expected output $txt_path: $!\n";
            local $/;
            my $out = <$fh>;
            close $fh;

            $out =~ s/\s+\z//;
            $out;
        };
        my $error = $@;

        remove_tree( $out_dir, { safe => 1 } );

        if ($error) {
            # A timeout at an automatically-selected model (never an
            # explicitly-passed one, TGT-100 follow-up: per-host
            # throughput varies too much for a duration guess alone to
            # guarantee correctness) automatically retries at the next
            # faster tier instead of failing outright.
            if ( !$explicit_model && $error =~ /timed out/ ) {
                my $next = _next_tier($model);
                if ( defined $next ) {
                    $model = $next;
                    next;
                }
            }
            die $error;
        }

        return $text;
    }
}

sub _run {
    my (@cmd) = @_;

    # TGT-144: fork+setpgrp-race-closing+devnull-redirect+exec was
    # identical, duplicated code shared with D2TG::TTS::_run - extracted
    # into D2TG::Subprocess (TGT-128's own process-group protection, so
    # a timeout can terminate the whole tree - whisper commonly shells
    # out to ffmpeg/ffprobe-family tooling - with one signal, not just
    # this immediate child). $FORKER is still threaded through so
    # existing tests injecting a fake fork-failure keep working
    # unchanged. Only the preamble moved; everything below (this
    # module's own waitpid poll loop and TERM/KILL escalation) is
    # unchanged.
    my $pid = D2TG::Subprocess::fork_in_own_process_group( cmd => [@cmd], forker => $FORKER );

    local $CURRENT_PID = $pid;
    my $deadline = time() + $TIMEOUT;

    while (1) {
        my $reaped = waitpid( $pid, WNOHANG );
        if ( $reaped == $pid ) {
            return $? >> 8;
        }

        if ( time() >= $deadline ) {
            # TGT-128: signal the whole process group, not just $pid, so
            # any child whisper itself spawned is terminated too - plus
            # the direct pid as a fallback (a Codex review finding on the
            # sibling TTS fix: a signal delivered straight to a pid can't
            # be missed by a process-group mismatch the way -$pid
            # targeting can, if setpgrp somehow never took effect on
            # either end).
            kill( 'TERM', -$pid );
            kill( 'TERM', $pid );
            sleep(1);

            # A further Codex review finding: gating the KILL escalation
            # on whether the group LEADER ($pid) itself was reaped missed
            # the case where the leader exits cleanly on TERM but a
            # descendant it spawned ignores TERM and survives - that
            # descendant would never receive a KILL at all. Always
            # escalate to KILL, unconditionally, for both the group and
            # the direct pid - sending KILL to an already-dead group/pid
            # is a harmless no-op (ESRCH), so this can never do anything
            # wrong, only ever close a real remaining gap.
            kill( 'KILL', -$pid );
            kill( 'KILL', $pid );
            waitpid( $pid, 0 );
            die "D2TG::Transcribe::_run: command timed out after ${TIMEOUT}s and was killed\n";
        }

        sleep(0.2);
    }
}

sub kill_current {
    return unless defined $CURRENT_PID;

    # TGT-131: signal the whole process group, matching _run's own
    # timeout-path kill (TGT-128) - a shutdown-triggered kill must reach
    # a child the tracked whisper process itself spawned exactly like a
    # timeout-triggered one already does, not leave it running just
    # because this is a separate call site into the same process.
    kill( 'TERM', -$CURRENT_PID );
    kill( 'TERM', $CURRENT_PID );
    return;
}

# TGT-237: retry_failed_download's own analogue for a queued failed
# voice transcription. Re-downloads the voice file transiently (never
# passed a `dir`, matching D2TG::Poller's own $transcribe_voice
# coderef - this download must never land in the shared, deduplicated
# attachments vault, and is always unlinked immediately below,
# regardless of outcome) and re-attempts D2TG::Transcribe::transcribe;
# on success, restores the message into D2TG::Store history via
# record_message (mirroring retry_failed_download's own TGT-104 Codex
# finding - a retry success must not only clear the queue row, leaving
# nothing for d2 tg.history/d2 tg.unread to show) and only then
# removes the queue row via D2TG::Poller::store_write_safe, the same
# established non-fatal store-write pattern; a record_message failure
# leaves the row queued rather than silently losing the transcript a
# second time.
sub retry_failed_transcription {
    my ( $telegram, $store, $row, %args ) = @_;

    my $local_path = eval { D2TG::Download::download_file( $telegram, $row->{file_id}, ua => $args{ua} ) };
    if ($@) {
        my $error = $@;
        $error =~ s/\n\z//;
        return ( 0, $error );
    }

    my $transcript = eval { transcribe($local_path) };
    my $transcribe_error = $@;
    unlink $local_path;

    if ($transcribe_error) {
        my $error = $transcribe_error;
        $error =~ s/\n\z//;
        return ( 0, $error );
    }

    # TGT-245: same fast-follow gap as retry_failed_download's own
    # record_message call above - $row->{bot_key} (TGT-237) must be
    # threaded through, or the restored transcript lands under the
    # default bot's history instead of the bot that actually received it.
    my ($record_ok) = D2TG::Poller::store_write_safe(
        $row->{chat_id}, 'record_message',
        sub {
            $store->record_message(
                $row->{chat_id}, $row->{message_id}, $row->{sender}, $transcript,
                bot_key => $row->{bot_key},
            );
        }
    );

    my $remove_ok;
    if ($record_ok) {

        # TGT-249 (found via a scheduled JOB-003 hourly bug hunt): the
        # removal write's own (ok, value) result must be inspected, not
        # discarded - a locked/busy database can make it fail
        # transiently too, and a still-queued row in that case (removal
        # write failed) must never be reported as fully complete.
        ($remove_ok) =
          D2TG::Poller::store_write_safe( $row->{chat_id}, 'remove_failed_transcription', sub { $store->remove_failed_transcription( $row->{id} ) } );
    }
    else {
        print STDERR "STORE ERROR [$row->{chat_id}]: queue row not removed - "
          . "a future retry can still restore history for this message, without re-transcribing\n";
    }

    # TGT-248 (found via a scheduled JOB-003 hourly bug hunt): mirrors
    # retry_failed_download's own $still_queued 3rd return value
    # (TGT-244/TGT-247) exactly. $ok=1 alone does not mean the retry is
    # FULLY complete - when record_message fails above, the row is
    # deliberately left in failed_transcriptions (never removed) and no
    # row was ever written into the messages table, so a caller printing
    # an unqualified success (as cli/retry-transcription.pl used to) is
    # misleading. A true 3rd return value here signals exactly that case.
    #
    # TGT-249: also true when record_message succeeded but the removal
    # write itself then failed - $remove_ok is undef in that case
    # (never attempted removal at all, or the attempt itself failed),
    # so still_queued must be true, not just when $record_ok is false.
    return ( 1, $transcript, ( $record_ok && $remove_ok ) ? 0 : 1 );
}

# TGT-246 (found via a scheduled JOB-003 hourly bug hunt): mirrors
# auto_retry_failed_downloads exactly, applied to failed_transcriptions
# instead - closes the same class of gap TGT-221 already closed for
# failed_downloads (Q-015 answered by Michael: retry every 60s for up to
# 5 minutes total, independent of poll cadence), which
# retry_failed_transcription (TGT-237) never got despite being built as
# failed_downloads' own explicit structural sibling. Called once per
# (chat_id group, bot) pair per poll cycle from cli/poller.pl's main
# loop, scoped to that pair's own bot_key (a retry needs the matching
# bot's own $telegram, since Telegram's file_id values are bot-token-
# scoped). Reuses retry_failed_transcription itself for the actual
# retry - only the "which rows, how often" selection logic is new
# (D2TG::Store::failed_transcriptions_due_for_retry). A row past the
# 5-minute window is silently skipped, not deleted - it stays fully
# visible/retryable via d2 tg.unread/d2 tg.retry-transcription exactly
# as before. Never dies - a locked/busy database or a retry failure
# must not turn this non-essential housekeeping into a poll-cycle
# failure, matching auto_retry_failed_downloads' own established
# non-fatal call-site pattern.
sub auto_retry_failed_transcriptions {
    my ( $telegram, $store, %args ) = @_;

    my $due = $store->failed_transcriptions_due_for_retry(
        defined $args{bot_key} ? ( bot_key => $args{bot_key} ) : ()
    );

    for my $row (@$due) {
        retry_failed_transcription( $telegram, $store, $row, ua => $args{ua} );

        # TGT-246: deliberately does NOT branch on retry_failed_transcription's
        # own ($ok, $result) return value - unlike retry_failed_download,
        # retry_failed_transcription always returns (1, $transcript) once
        # download+transcription succeed, EVEN when the bookkeeping
        # record_message write that follows then fails and the row is
        # deliberately left queued (its own "STORE ERROR ... queue row
        # not removed" comment). Trusting $ok alone here would repeat
        # exactly the throttle-bypass bug TGT-244 fixed for
        # auto_retry_failed_downloads: a row stuck in that partial-
        # success state would never get last_retry_at stamped and would
        # be retried on every single poll cycle instead of once per
        # AUTO_RETRY_INTERVAL_SECONDS. Checking the queue directly after
        # the attempt is unambiguous regardless of which step failed
        # (download, transcription, or record_message) and needs no
        # change to retry_failed_transcription's own existing contract
        # (out of this ticket's scope).
        my $still_queued = grep { $_->{id} == $row->{id} } @{ $store->failed_transcriptions };
        if ($still_queued) {
            eval { $store->mark_failed_transcription_retried( $row->{id} ) };
        }
    }

    return;
}

1;

=head1 NAME

D2TG::Transcribe - transcribe an audio file via a local Whisper install

=head1 SYNOPSIS

    my $text = D2TG::Transcribe::transcribe($audio_path);

=head1 DESCRIPTION

Shells out to a local C<whisper> CLI (no Perl binding exists) to
transcribe C<$audio_path>, per Q-002's choice of local Whisper over a
cloud transcription service. Per the blueprint, refuses any C<*.en>
(English-only) model checkpoint - only multilingual models are used.

=head1 FUNCTIONS

=head2 select_model($duration_seconds)

Returns a Whisper model name tiered by audio duration (TGT-100, a live
user request): C<base> for a genuinely short, parsed duration in
C<(0, 60]> (TGT-251, a live user request - Michael reported a 30-second
clip taking "like forever"; C<medium> at the ~5.6x real-time throughput
measured below means a clip that short still cost roughly 168 seconds of
wall time under the old C<<=300s>> boundary), C<medium> up to 300 seconds
otherwise, C<small> up to 900 seconds, C<base> beyond that - a
I<starting-point guess> only. An unparsed or failed duration (C<undef>,
non-numeric, or a failed probe - see L</transcribe>) is deliberately
I<not> swept into the new short-clip tier merely because it coerces to
0: an unknown duration keeps falling back to C<medium> exactly as
before TGT-251, since an unknown duration is not the same claim as a
confirmed-short one. Per-host Whisper throughput varies far more than
audio duration alone predicts (measured on one host: C<medium> ran at
~5.6x real time with no GPU, so a 102-second clip took 9m31s, well
inside this function's own 300-second "stays on medium" boundary) - see
L</transcribe>'s automatic retry-on-timeout for what actually guarantees
a long/slow clip doesn't get lost.

=head2 _scaled_timeout($duration_seconds)

TGT-140 (external review finding, confirmed live by Michael): C<$TIMEOUT>
alone stayed a flat 300 seconds even after L</select_model> started tiering
the model by duration - a clip picked as the fastest/default tier could
still legitimately run past 300s wall-clock at real per-host throughput
(measured: C<medium> ran at ~5.6x real time, so a 102.48-second clip took
571s). Returns a per-attempt timeout budget scaled from the same duration
signal L</select_model> already computes: C<$duration * $TIMEOUT_MULTIPLIER>
(package variable, default 8 - a safety margin above the worst measured
throughput), floored at C<$TIMEOUT> itself (whatever it is currently set
to - never a separate hard-coded constant, so a caller-configured
C<$TIMEOUT> is always respected as the minimum, not silently
overridden) and capped at C<$TIMEOUT_CEILING> (default 3600, so a
bad/huge duration probe can never produce an effectively unbounded
wait) - the effective ceiling actually used is
C<max($TIMEOUT_CEILING, $TIMEOUT)>, so a caller-configured C<$TIMEOUT>
larger than the default ceiling is never undercut by the cap either (a
Codex QA-stage review finding: flooring at C<$TIMEOUT> then capping at a
fixed ceiling could otherwise return less than C<$TIMEOUT> itself).

=head2 _next_tier($model)

Returns the next entry in C<@MODEL_TIERS> (C<medium>, C<small>,
C<base>, in that order) after C<$model>, or C<undef> if C<$model> is
already C<base> or not one of the three known tiers (e.g. an
explicitly-passed custom model name) - the latter case deliberately
gives L</transcribe> no fallback to step down to, since retry-on-timeout
only ever applies to an automatically-selected model.

=head2 _probe_duration($audio_path)

Returns C<$audio_path>'s duration in seconds via C<ffprobe>, invoked
through L<D2TG::Subprocess/fork_in_own_process_group> (never a shell
string, so the path can never reach a shell) with its own C<stdout>
capture support (TGT-179), the same process-group-killable subprocess
launch C<_run> below uses for whisper. Waits under a
C<waitpid(WNOHANG)> poll loop, checked every 0.2s, that kills on
timeout once C<$PROBE_TIMEOUT> (10s default) has elapsed - the actual
wait can run up to roughly that poll interval past the deadline
(scheduler delay aside), not an exact cutoff, which is a fine
trade-off for a probe this short-lived. Not a plain
C<alarm()>-around-a-blocking-readline, which
does NOT reliably interrupt a buffered pipe read (PerlIO retries on
C<EINTR> without giving Perl a chance to run a deferred C<SIGALRM>
handler mid-read), confirmed directly: an earlier attempt at exactly
that approach still blocked for the hung command's full duration in
testing. On timeout, kills the process group and the direct pid (same
escalation C<_run> uses) and falls back to 0 seconds, exactly like a
missing/corrupt-output probe already did before this fix - a hang no
longer blocks the entire single-threaded poller indefinitely to get
there. C<transcribe> calls this only when no explicit C<model> was
given.

=head2 transcribe($audio_path, model => $name, runner => \&coderef, duration_fn => \&coderef)

Runs C<whisper> against C<$audio_path> with the given C<model> (default:
L</select_model>'s answer for the audio's own duration, TGT-100 -
previously always the fixed C<medium>), reads back its
C<--output_format txt> transcript, and returns the trimmed text. Dies if
C<model> ends in C<.en>, if C<whisper> exits non-zero, or if its expected
output file is missing.

When C<model> was I<not> explicitly passed, the same probed duration used
to pick the model also scales the hard timeout C<_run> enforces for that
attempt (TGT-140, via L</_scaled_timeout>, C<local>ized around the runner
call) - a clip whose own tier's real throughput legitimately takes longer
than the old flat 300s no longer gets killed purely for that. An
explicitly-passed C<model> keeps the flat package C<$TIMEOUT> unchanged,
matching the same explicit-means-explicit scope the retry-on-timeout
fallback below already uses.

If C<model> was I<not> explicitly passed and the run times out
(C<_run>'s C<"...timed out..."> die), C<transcribe> automatically
retries at L</_next_tier>'s next-faster model instead of dying
immediately - TGT-100's follow-up, since a fixed duration-based guess
alone can't account for how much per-host Whisper throughput varies
(measured: C<medium> at ~5.6x real time on one host). Retrying continues
until a model succeeds or C<base> itself times out, at which point the
timeout error finally propagates. An explicitly-passed C<model> is never
automatically retried - only the automatically-selected starting model
gets this fallback.

C<duration_fn> is an optional coderef taking the
audio path and returning its duration in seconds; it defaults to
L</_probe_duration> and exists so callers (tests) can inject a fake
instead of invoking a real C<ffprobe>. The
whisper-output temp directory is removed after every attempt (success,
non-retryable failure, or before a retry) - it is not left for
process-exit cleanup, since a long-running poller could otherwise
accumulate one per transcription attempt for the life of the process.
C<runner> is an optional coderef taking a command's argument list and
returning its exit status; it defaults to C<_run> (TGT-031: a bounded,
killable subprocess, no longer a plain C<system(@cmd)> call), and exists
so callers (tests) can inject a fake runner instead of invoking a real
subprocess.

=head2 _run(@cmd)

Runs C<@cmd> in a child forked via the package variable C<$FORKER>
(defaults to a plain C<fork()> call; tests inject a fake here to
exercise the fork-failure path, since a real C<fork()> is not something
a test can reliably make fail on demand) - never via a shell, so no
injection risk - polling C<waitpid> every 0.2s instead of blocking on
it directly, so a
pending signal in the caller (e.g. C<cli/poller.pl>'s C<SIGINT>/C<SIGTERM>
handler) gets a chance to run promptly rather than being deferred until
the child exits (TGT-031: this was the root cause of the poller
appearing unresponsive to Ctrl+C while transcribing). If C<@cmd> has not
exited by C<$TIMEOUT> seconds (package variable, default 300, settable
per-call via C<local>), the whole process group is sent C<TERM>
(TGT-128, same failure class as TGT-035/044/126/127: C<whisper>
commonly shells out to C<ffmpeg>/C<ffprobe>-family tooling for audio
decoding, and killing only the immediate pid left any such child
running/orphaned), given one second to exit, then C<KILL>ed the same
way if still alive - C<_run> then dies with a timeout-specific message
rather than returning. On normal exit, returns the command's exit
status as before.

Both the child (C<setpgrp(0, 0)>) and the parent
(C<eval { setpgrp($pid, $pid) }>) set the child's process group
immediately after C<fork> - deliberately redundant, closing a race the
sibling L<D2TG::TTS>C</_run> fix's own Codex review caught: without the
parent's own call too, a timeout firing before the child's C<setpgrp>
call would target a process group that does not exist yet, and C<kill>
would silently do nothing. Both the group kill (C<-$pid>) and a direct
kill on the known pid (C<$pid>) are sent on both the C<TERM> and C<KILL>
steps - the direct kill is a fallback in case process-group targeting
somehow misses the child. Accepted, documented limitation (matching the
sibling fix): a grandchild that deliberately detaches into its own new
process group/session would not be reached by this kill.

Before C<exec>, the child reopens its own C<STDOUT>/C<STDERR> onto
C<File::Spec-E<gt>devnull> (TGT-030: C<whisper>'s own console chatter -
warnings, language-detection lines, per-segment transcript output - was
otherwise inherited straight onto the poller's real stdout, polluting
the watched C<NEW TG> stream). Only the child's descriptors are
touched; the parent's own C<STDOUT>/C<STDERR> are never redirected.

=head2 kill_current()

Sends C<TERM> to the process currently running under C<_run>, if any
(tracked in the package variable C<$CURRENT_PID>, correctly visible to a
signal handler that fires during C<_run>'s poll loop since it is set via
C<local>). A no-op when nothing is running. C<cli/poller.pl> calls this
from its own shutdown signal handlers so an in-flight transcription is
killed immediately instead of being waited out.

TGT-131 (a consistency follow-up to TGT-128): signals the whole process
group (C<-$CURRENT_PID>) as well as the direct pid, matching C<_run>'s
own timeout-path process-group protection - without this, a clean
poller shutdown could still leave a child C<whisper> itself spawned
running, even though the same process's own timeout path already
reached it.

=head2 retry_failed_transcription($telegram, $store, $row, ua => $optional_client)

TGT-237: L<D2TG::Download/retry_failed_download>'s own analogue for one
L<D2TG::Store/failed_transcriptions> row - C<$row> is one of the
hashrefs that method returns (C<id>, C<chat_id>, C<message_id>,
C<file_id>, C<sender>, C<error>). Returns C<(1, $transcript)> on
success or C<(0, $error)> on failure, the same shape convention as
L<D2TG::Download/retry_failed_download>.

Re-downloads the voice file via L<D2TG::Download/download_file> with no C<dir>
argument (transient, matching C<cli/poller.pl>'s own
C<$transcribe_voice> coderef exactly - this download must never land
in the shared, deduplicated attachments vault) and re-attempts
L<D2TG::Transcribe/transcribe>; the downloaded file is C<unlink>ed
immediately afterward regardless of outcome. On success, restores the
message into C<$store>'s own history via C<record_message> (the
transcript itself as the summary - unlike L<D2TG::Download/retry_failed_download>,
there is no real local path to hide, since a transcript is text, not a
filesystem location), also passing C<< bot_key => $row->{bot_key} >>
through (TGT-245 - the same missed-call-site fast-follow gap from
TGT-232 that L<D2TG::Download/retry_failed_download> above had, fixed the same way)
before removing the queue row via
L<D2TG::Store/remove_failed_transcription> - both calls go through
L<D2TG::Poller/store_write_safe>, matching L<D2TG::Download/retry_failed_download>'s
own established non-fatal store-write pattern; a C<record_message>
failure leaves the row queued (logged as C<STORE ERROR [chat_id]:
queue row not removed - ...>) rather than losing the transcript a
second time. On a download or transcription failure, the row is left
completely untouched - never removed - so the caller (C<cli/retry-transcription.pl>)
can retry again later.

=head2 auto_retry_failed_transcriptions($telegram, $store, bot_key => $b, ua => $optional_client)

TGT-246 (found via a scheduled JOB-003 hourly bug hunt): mirrors
L<D2TG::Download/auto_retry_failed_downloads> exactly, applied to
C<failed_transcriptions> instead - closes the same class of gap TGT-221
already closed for C<failed_downloads> (Q-015 answered by Michael:
retry every 60s for up to 5 minutes total, independent of poll cadence),
which C<retry_failed_transcription> (TGT-237) never got despite being
explicitly built as C<failed_downloads>' own structural sibling - before
this, a transient transcription failure sat queued until a human/agent
ran C<d2 tg.retry-transcription> by hand, with no automatic recovery at
all. Selects rows via L<D2TG::Store/failed_transcriptions_due_for_retry>
and reuses L</retry_failed_transcription> itself for the actual retry
attempt (no duplicated retry logic).

Deliberately does NOT branch on C<retry_failed_transcription>'s own
C<($ok, $result)> return value to decide whether to stamp
C<last_retry_at> - unlike L<D2TG::Download/retry_failed_download>, C<retry_failed_transcription>
always returns C<(1, $transcript)> once download and transcription both
succeed, I<even when> the bookkeeping C<record_message> write that
follows then fails and the row is deliberately left queued (its own
C<STORE ERROR ... queue row not removed> path). Trusting C<$ok> alone
here would repeat exactly the throttle-bypass bug TGT-244 fixed for
L<D2TG::Download/auto_retry_failed_downloads>: a row stuck in that partial-success
state would never get C<last_retry_at> stamped and would be retried on
every single poll cycle instead of once per
C<AUTO_RETRY_INTERVAL_SECONDS>. Instead, this checks
L<D2TG::Store/failed_transcriptions> directly after the attempt for
whether the row still exists - unambiguous regardless of which step
failed (download, transcription, or C<record_message>), and requires no
change to C<retry_failed_transcription>'s own existing return contract.

Intended to be called once per C<(chat_id group, bot)> pair per poll
cycle from C<cli/poller.pl>'s main loop, scoped to that pair's own
C<bot_key> - a retry needs the matching bot's own C<$telegram>, since
Telegram's C<file_id> values are bot-token-scoped. Never dies - a
locked/busy database or a retry failure must not turn this non-essential
housekeeping into a poll-cycle failure, matching
L<D2TG::Download/auto_retry_failed_downloads>'s own established non-fatal call-site
pattern.


=head1 KNOWN LIMITATION

There is a narrow window, a few instructions wide, between C<fork()>
returning in C<_run> and C<$CURRENT_PID> actually being set - a signal
arriving in that exact window sees the previous (unset) value and
C<kill_current> becomes a no-op for that specific child. The child is
still bounded by C<$TIMEOUT> regardless, so this cannot cause an
indefinite hang; it can only delay a shutdown signal's effect on that
one child by up to C<$TIMEOUT>, in the statistically negligible case a
signal lands in that exact instant.

=cut
