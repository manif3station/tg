package D2TG::Transcribe;

use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Spec;
use File::Basename qw(fileparse);
use File::Path qw(remove_tree);

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
    return system(@cmd);
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
exit status; it defaults to a plain C<system(@cmd)> call, and exists so
callers (tests) can inject a fake runner instead of invoking a real
subprocess.

=cut
