package D2TG::TTS;

use strict;
use warnings;
use File::Temp qw(tempfile);
use File::Spec;
use File::Copy qw(copy);
use D2TG::Subprocess;

use constant DEFAULT_HARD_TIMEOUT => 60;

# TGT-127: mutable copy of the constant above, so a test can force a fast
# timeout via `local $D2TG::TTS::HARD_TIMEOUT = 1` without waiting out the
# real production bound - mirrors the injectable-coderef pattern used
# elsewhere in this module (runner/renamer) for the same reason.
our $HARD_TIMEOUT = DEFAULT_HARD_TIMEOUT;

sub synthesize {
    my ( $text, %args ) = @_;

    die "D2TG::TTS::synthesize: text must not be empty\n"
      unless defined $text && length $text;

    my $runner = $args{runner} || \&_run;

    my ( $mp3_fh, $mp3_path ) = tempfile( SUFFIX => '.mp3', UNLINK => 0 );
    close $mp3_fh;
    my ( $ogg_fh, $ogg_path ) = tempfile( SUFFIX => '.ogg', UNLINK => 0 );
    close $ogg_fh;

    my $gtts_rc = eval { $runner->( 'gtts-cli', $text, '--output', $mp3_path ) };
    if ( my $err = $@ ) {
        unlink $mp3_path, $ogg_path;
        die $err;
    }
    if ( $gtts_rc != 0 ) {
        unlink $mp3_path, $ogg_path;
        die "D2TG::TTS::synthesize: gtts-cli failed for text synthesis\n";
    }

    my $ffmpeg_rc = eval { $runner->( 'ffmpeg', '-y', '-i', $mp3_path, '-c:a', 'libopus', $ogg_path ) };
    if ( my $err = $@ ) {
        unlink $mp3_path, $ogg_path;
        die $err;
    }
    if ( $ffmpeg_rc != 0 ) {
        unlink $mp3_path, $ogg_path;
        die "D2TG::TTS::synthesize: ffmpeg conversion to ogg/opus failed\n";
    }

    unlink $mp3_path;
    return $ogg_path;
}

sub synthesize_to_file {
    my ( $text, %args ) = @_;

    my $ogg_path = synthesize( $text, runner => $args{runner} );

    return $ogg_path unless defined $args{out};

    # Codex review finding: File::Copy::move silently drops the file
    # INTO an existing directory target instead of failing, which would
    # make this return/print the directory's own path, not the file
    # actually written - reject that shape explicitly instead.
    if ( -d $args{out} ) {
        unlink $ogg_path;
        die "D2TG::TTS::synthesize_to_file: $args{out} is a directory, not a file path\n";
    }

    # Codex review finding (second round): an earlier version of this
    # cleaned up ANY file left at $args{out} after a failed move,
    # including a pre-existing, unrelated file that was already there
    # before this call - a real destructive bug (a move can fail for
    # reasons that have nothing to do with a partial write this call
    # produced). Move into a same-directory temp name first, so a
    # failure at either step never touches $args{out} at all; only the
    # final, separate rename actually replaces it, atomically, and only
    # once the file is fully and successfully in place.
    # Codex review finding (third round): a predictable staging name
    # ("$$-" . time()) can collide between concurrent/re-entrant calls,
    # or be pre-empted by an unrelated file of the same name - reserve
    # the staging path exclusively via File::Temp instead of hand-
    # rolling uniqueness, and write into that already-reserved file
    # (via copy, not move) so there is never a window where the name is
    # reserved but not actually owned by this call.
    my ( undef, $out_dir, undef ) = File::Spec->splitpath( $args{out} );
    $out_dir = '.' unless length $out_dir;
    my ( $staging_fh, $staging_path ) =
      eval { tempfile( 'd2tg-tts-XXXXXXXX', DIR => $out_dir, SUFFIX => '.ogg', UNLINK => 0 ) };
    if ($@) {
        my $err = $@;
        unlink $ogg_path;
        die "D2TG::TTS::synthesize_to_file: cannot write to $args{out}: $err";
    }
    close $staging_fh;

    # $renamer exists purely for test injection (mirroring $runner
    # above) - the final rename() succeeding is otherwise very hard to
    # force to fail deterministically without real, exotic filesystem
    # conditions (it's the one step guaranteed to be same-filesystem by
    # construction).
    my $renamer = $args{renamer} || sub { return rename( $_[0], $_[1] ); };

    # Codex review finding: $! must be captured immediately after
    # whichever step actually failed - the later `unlink $ogg_path`
    # call (needed regardless of outcome) would otherwise silently
    # clobber a real copy() failure's own errno before it's ever read.
    my $copied    = copy( $ogg_path, $staging_path );
    my $copy_err  = $!;
    unlink $ogg_path;
    my $renamed   = $copied && $renamer->( $staging_path, $args{out} );
    my $rename_err = $!;

    unless ($renamed) {
        my $err = $copied ? $rename_err : $copy_err;
        unlink $staging_path;
        die "D2TG::TTS::synthesize_to_file: cannot write to $args{out}: $err\n";
    }

    return $args{out};
}

sub _run {
    my (@cmd) = @_;

    # TGT-144: fork+setpgrp-race-closing+devnull-redirect+exec was
    # identical, duplicated code shared with D2TG::Transcribe::_run -
    # extracted into D2TG::Subprocess (TGT-127's own process-group
    # protection, so a timeout can kill the whole tree - gtts-cli/ffmpeg
    # may themselves spawn children - with one signal, not just this
    # immediate child). Only the preamble moved; everything below
    # (this module's own alarm-based wait/timeout logic) is unchanged.
    my $pid = D2TG::Subprocess::fork_in_own_process_group( cmd => [@cmd] );

    my $rc;
    my $timed_out = 0;
    eval {
        local $SIG{ALRM} = sub {
            $timed_out = 1;
            die "D2TG::TTS::_run: command timed out after ${HARD_TIMEOUT}s\n";
        };
        alarm($HARD_TIMEOUT);
        waitpid( $pid, 0 );
        alarm(0);
        $rc = $?;
    };
    my $error = $@;
    alarm(0);

    if ($timed_out) {
        # A further Codex review finding: the group kill above only
        # reaches the child if its own/our own setpgrp actually took
        # effect - belt-and-braces, also kill the known immediate pid
        # directly (a signal delivered straight to a pid can't be missed
        # by a process-group mismatch the way -$pid targeting can), so
        # the following waitpid is never left blocking on a still-alive
        # process that the group kill happened to miss.
        kill( 'KILL', -$pid );
        kill( 'KILL', $pid );
        waitpid( $pid, 0 );
        die $error;
    }
    die $error if $error;

    return $rc;
}

1;

=head1 NAME

D2TG::TTS - text-to-speech synthesis for voice-note replies

=head1 SYNOPSIS

    my $ogg_path = D2TG::TTS::synthesize($text);

=head1 DESCRIPTION

Synthesizes C<$text> into an Ogg/Opus audio file suitable for Telegram's
C<sendVoice>, via cloud gTTS (chosen per Q-001) piped through C<ffmpeg>
for codec conversion. There is no Perl gTTS binding, so both steps shell
out to external commands.

Per the owner's design brief, a reply is never sent as text-only: if
either step fails, C<synthesize> dies and the caller (L<D2TG::Reply>)
never attempts to send anything.

=head1 FUNCTIONS

=head2 synthesize($text, runner => \&coderef)

Runs C<gtts-cli> to produce an MP3, then C<ffmpeg> to convert it to
Ogg/Opus, returning the path to the resulting C<.ogg> file. Dies with a
descriptive message (and cleans up any partial temp files) if either step
exits non-zero, or if C<$text> is empty.

C<runner> is an optional coderef taking a command's argument list and
returning its exit status (0 for success); it defaults to C<_run>
(fork/exec, no shell, under a hard timeout - see L</_run>), and exists
so callers (tests) can inject a fake runner instead of invoking real
subprocesses. A thrown error from C<runner> (e.g. C<_run>'s own timeout
death) is treated the same as a non-zero exit status: temp files are
cleaned up and the error re-thrown.

=head2 synthesize_to_file($text, out => $path, runner => \&coderef, renamer => \&coderef)

TGT-106 (user-supplied feature-gap analysis): C<synthesize> itself is
unchanged - this wraps it with the "write the result somewhere specific,
or return a sensible default location" plumbing that C<cli/tts.pl>
needs to expose synthesis as its own standalone command, matching the
old C<~/skills/tg> blueprint's own separate TTS step (previously only
reachable from inside L<D2TG::Reply/send_reply>).

Calls C<synthesize($text, runner => $runner)> exactly as before. With no
C<out>, returns that C<.ogg> path unchanged (a real, already-existing
file - the sensible default). With C<out> given, an existing directory
there is refused outright (a Codex review finding: C<File::Copy::move>
would otherwise silently drop the file inside it instead of failing,
so the returned path would name the directory, not the file actually
written). Otherwise the synthesized file is moved into a same-directory
staging name first, then a single C<rename()> atomically replaces
C<$path> with it - only once the file is fully and successfully in
place. A failure at either step (synthesis, the move, or the rename)
dies loudly and never touches C<$path> itself at all - a second Codex
review round caught that an earlier version's cleanup logic could
delete a I<pre-existing, unrelated> file already sitting at C<$path>
after a failed write, which had nothing to do with the failure. Fully
matches this skill's fail-loud TTS convention: no file is ever left
empty, partially written, or lost as a side effect of a failed attempt.

The staging file's own name is reserved exclusively via
L<File::Temp/tempfile> (a third Codex review round: a hand-rolled
"$$-time()" name could collide between concurrent/re-entrant calls),
in the same directory as C<$path> - a same-filesystem rename is what
makes the final replace atomic and safe from a partial cross-filesystem
copy. C<renamer> is an optional coderef (mirroring C<runner>'s own
injection point) taking the staging and destination paths and returning
true on success; it exists purely so tests can force the otherwise
very-hard-to-trigger "everything succeeded up to the final same-
directory rename, and then that one step itself failed" case
deterministically.

Accepted, documented limitation (a Codex review raised it, not fixed
here as disproportionate to this ticket's own scope): between the
staging path being reserved and C<copy> writing to it, another process
with write access to the same directory could in principle replace it
with a symlink (a classic TOCTOU race) - relevant only if C<--out>'s
directory is itself writable by an untrusted party, which is true of
any local file this skill writes regardless of this function.


=head2 _run(@cmd)

Runs C<@cmd> in its own forked child (own process group, C<STDOUT>/
C<STDERR> redirected to C<File::Spec-E<gt>devnull> - TGT-033, mirroring
TGT-030's fix for L<D2TG::Transcribe>), waiting under a SIGALRM hard
timeout (TGT-127, same failure class as TGT-035/TGT-044/TGT-126: a
bare C<system(@cmd)> here had no timeout at all, and C<gtts-cli> makes
a real network call to Google's TTS endpoint that could hang
indefinitely). C<$D2TG::TTS::HARD_TIMEOUT> (default
C<DEFAULT_HARD_TIMEOUT>, 60s - generous enough for the max ~5000-char
text this skill ever sends, TGT-035) bounds the wait; on timeout, the
whole child process group is killed (C<kill('KILL', -$pid)>, not just
the immediate child - C<gtts-cli>/C<ffmpeg> could themselves spawn
children) and reaped before C<_run> dies with a clear timeout message.
Both the child (C<setpgrp(0, 0)>) and the parent
(C<eval { setpgrp($pid, $pid) }>) set the child's process group
immediately after C<fork> - deliberately redundant, closing a real race
a Codex review caught: without the parent's own call too, a timeout
firing before the child's C<setpgrp> call would target a process group
that does not exist yet, and C<kill> would silently do nothing.
Accepted, documented limitation: a grandchild that deliberately detaches
into its own new process group/session would not be reached by this
kill - not expected of C<gtts-cli>/C<ffmpeg>'s own normal operation, but
not an absolute guarantee either.

C<$HARD_TIMEOUT> is a mutable package variable, not a plain constant,
specifically so a test can force a fast timeout via
C<local $D2TG::TTS::HARD_TIMEOUT = 1> without waiting out the real
production bound.

=cut
