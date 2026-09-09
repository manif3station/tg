package D2TG::TTS;

use strict;
use warnings;
use File::Temp qw(tempfile);
use File::Spec;
use File::Copy qw(move);

sub synthesize {
    my ( $text, %args ) = @_;

    die "D2TG::TTS::synthesize: text must not be empty\n"
      unless defined $text && length $text;

    my $runner = $args{runner} || \&_run;

    my ( $mp3_fh, $mp3_path ) = tempfile( SUFFIX => '.mp3', UNLINK => 0 );
    close $mp3_fh;
    my ( $ogg_fh, $ogg_path ) = tempfile( SUFFIX => '.ogg', UNLINK => 0 );
    close $ogg_fh;

    if ( $runner->( 'gtts-cli', $text, '--output', $mp3_path ) != 0 ) {
        unlink $mp3_path, $ogg_path;
        die "D2TG::TTS::synthesize: gtts-cli failed for text synthesis\n";
    }

    if ( $runner->( 'ffmpeg', '-y', '-i', $mp3_path, '-c:a', 'libopus', $ogg_path ) != 0 ) {
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
    my ( $out_vol, $out_dir, undef ) = File::Spec->splitpath( $args{out} );
    my $staging_path = File::Spec->catpath( $out_vol, $out_dir, ".d2tg-tts-$$-" . time() . '.ogg' );

    my $moved   = move( $ogg_path, $staging_path );
    my $renamed = $moved && rename( $staging_path, $args{out} );

    unless ($renamed) {
        my $err = $!;
        unlink $ogg_path, $staging_path;
        die "D2TG::TTS::synthesize_to_file: cannot write to $args{out}: $err\n";
    }

    return $args{out};
}

sub _run {
    my (@cmd) = @_;

    open my $saved_stdout, '>&', \*STDOUT or die "D2TG::TTS::_run: cannot save STDOUT: $!\n";
    open my $saved_stderr, '>&', \*STDERR or die "D2TG::TTS::_run: cannot save STDERR: $!\n";

    open STDOUT, '>', File::Spec->devnull or die "D2TG::TTS::_run: cannot redirect STDOUT: $!\n";
    open STDERR, '>', File::Spec->devnull or die "D2TG::TTS::_run: cannot redirect STDERR: $!\n";

    my $rc = system(@cmd);

    open STDOUT, '>&', $saved_stdout or die "D2TG::TTS::_run: cannot restore STDOUT: $!\n";
    open STDERR, '>&', $saved_stderr or die "D2TG::TTS::_run: cannot restore STDERR: $!\n";

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
(list-form C<system(@cmd)>, no shell), and exists so callers (tests) can
inject a fake runner instead of invoking real subprocesses.

=head2 synthesize_to_file($text, out => $path, runner => \&coderef)

TGT-106 (user-supplied feature-gap analysis): C<synthesize> itself is
unchanged - this wraps it with the "write the result somewhere specific,
or return a sensible default location" plumbing that C<cli/tts.pl>
needs to expose synthesis as its own standalone command, matching the
old C<~/skills/tg> blueprint's own separate TTS step (previously only
reachable from inside L<D2TG::Reply/send_reply>).

Calls C<synthesize($text, runner => $runner)> exactly as before. With no
C<out>, returns that C<.ogg> path unchanged (a real, already-existing
file - the sensible default). With C<out> given, moves the synthesized
file there (via L<File::Copy/move>, which falls back to copy+unlink
across filesystems) and returns C<$path> instead. A synthesis failure
still dies exactly as C<synthesize> already does - fail-loud, no file
ever left at C<$path> on failure, matching this skill's TTS convention
(never a silent empty/missing output).

=head2 _run(@cmd)

Runs C<@cmd> via C<system>, with C<STDOUT>/C<STDERR> temporarily
redirected to C<File::Spec-E<gt>devnull> for the duration of the call
and restored immediately afterward (TGT-033, mirroring TGT-030's fix
for L<D2TG::Transcribe>) - C<gtts-cli>/C<ffmpeg>'s own console output
never reaches the caller's real stdout/stderr.

=cut
