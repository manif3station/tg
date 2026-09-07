package D2TG::Transcribe;

use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Spec;
use File::Basename qw(fileparse);
use File::Path qw(remove_tree);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);

our $TIMEOUT     = 300;
our $CURRENT_PID = undef;
our $FORKER      = sub { return fork() };

sub transcribe {
    my ( $audio_path, %args ) = @_;

    my $model = $args{model} || 'medium';
    die "D2TG::Transcribe::transcribe: model must not be an English-only (.en) checkpoint\n"
      if $model =~ /\.en$/;

    my $runner  = $args{runner} || \&_run;
    my $out_dir = tempdir( CLEANUP => 0 );

    my $text = eval {
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
    die $error if $error;

    return $text;
}

sub _run {
    my (@cmd) = @_;

    my $pid = $FORKER->();
    die "D2TG::Transcribe::_run: fork failed: $!\n" unless defined $pid;

    if ( $pid == 0 ) {
        open( STDOUT, '>', File::Spec->devnull ) or POSIX::_exit(127);
        open( STDERR, '>', File::Spec->devnull ) or POSIX::_exit(127);
        exec(@cmd) or POSIX::_exit(127);
    }

    local $CURRENT_PID = $pid;
    my $deadline = time() + $TIMEOUT;

    while (1) {
        my $reaped = waitpid( $pid, WNOHANG );
        if ( $reaped == $pid ) {
            return $? >> 8;
        }

        if ( time() >= $deadline ) {
            kill( 'TERM', $pid );
            sleep(1);
            kill( 'KILL', $pid ) if waitpid( $pid, WNOHANG ) != $pid;
            waitpid( $pid, 0 );
            die "D2TG::Transcribe::_run: command timed out after ${TIMEOUT}s and was killed\n";
        }

        sleep(0.2);
    }
}

sub kill_current {
    return unless defined $CURRENT_PID;
    kill( 'TERM', $CURRENT_PID );
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

=head2 transcribe($audio_path, model => $name, runner => \&coderef)

Runs C<whisper> against C<$audio_path> with the given C<model> (default
C<medium>), reads back its C<--output_format txt> transcript, and
returns the trimmed text. Dies if C<model> ends in C<.en>, if C<whisper>
exits non-zero, or if its expected output file is missing. The
whisper-output temp directory is removed before returning or dying
either way - it is not left for process-exit cleanup, since a
long-running poller could otherwise accumulate one per transcribed
voice note for the life of the process. C<runner> is
an optional coderef taking a command's argument list and returning its
exit status; it defaults to C<_run> (TGT-031: a bounded, killable
subprocess, no longer a plain C<system(@cmd)> call), and exists so
callers (tests) can inject a fake runner instead of invoking a real
subprocess.

=head2 _run(@cmd)

Runs C<@cmd> in a child forked via the package variable C<$FORKER>
(defaults to a plain C<fork()> call; tests inject a fake here to
exercise the fork-failure path, since a real C<fork()> is not something
a test can reliably make fail on demand) - never via a shell, so no
injection risk - polling C<waitpid> every 0.2s instead of blocking on
it directly, so a
pending signal in the caller (e.g. C<cli/poller>'s C<SIGINT>/C<SIGTERM>
handler) gets a chance to run promptly rather than being deferred until
the child exits (TGT-031: this was the root cause of the poller
appearing unresponsive to Ctrl+C while transcribing). If C<@cmd> has not
exited by C<$TIMEOUT> seconds (package variable, default 300, settable
per-call via C<local>), it is sent C<TERM>, given one second to exit,
then C<KILL>ed if still alive - C<_run> then dies with a
timeout-specific message rather than returning. On normal exit, returns
the command's exit status as before.

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
C<local>). A no-op when nothing is running. C<cli/poller> calls this
from its own shutdown signal handlers so an in-flight transcription is
killed immediately instead of being waited out.

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
