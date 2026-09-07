package D2TG::TTS;

use strict;
use warnings;
use File::Temp qw(tempfile);

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

sub _run {
    my (@cmd) = @_;
    return system(@cmd);
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
returning its exit status (0 for success); it defaults to a plain
C<system(@cmd)> call, and exists so callers (tests) can inject a fake
runner instead of invoking real subprocesses.

=cut
