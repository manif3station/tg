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

# TGT-320: shared by select_model and _probe_duration - both need to
# know whether a string is a genuine single decimal number (not just
# built from the digits-and-dots character class, which also matches
# malformed values like '1.2.3' or '...' and would silently numify with
# a Perl "isn't numeric" warning under the old per-site regex).
sub _looks_like_duration {
    my ($str) = @_;
    return defined $str && $str =~ /^\s*\d+(?:\.\d+)?\s*$/;
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
    my $parsed = _looks_like_duration($duration);
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
    return 0 unless _looks_like_duration($duration);
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

1;
