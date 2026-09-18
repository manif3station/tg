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
