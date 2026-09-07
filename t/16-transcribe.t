use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);
use File::Spec;

require D2TG::Transcribe;

{
    eval { D2TG::Transcribe::transcribe( '/tmp/whatever.oga', model => 'medium.en' ) };
    like( $@, qr/English-only/, 'transcribe refuses an *.en (English-only) model' );
}

{
    my $out_dir;
    my $runner = sub {
        my (@cmd) = @_;
        # find --output_dir argument to know where to write the fake transcript
        my ($i) = grep { $cmd[$_] eq '--output_dir' } 0 .. $#cmd;
        $out_dir = $cmd[ $i + 1 ];
        open my $fh, '>', File::Spec->catfile( $out_dir, 'sample.txt' ) or die $!;
        print {$fh} "hello from whisper\n";
        close $fh;
        return 0;
    };

    my $text = D2TG::Transcribe::transcribe( '/tmp/sample.oga', model => 'medium', runner => $runner );

    is( $text, 'hello from whisper', 'transcribe returns the trimmed transcript text' );
    ok( !-d $out_dir, 'the whisper-output temp directory is removed after a successful transcribe' );
}

{
    my $out_dir;
    my $runner = sub {
        my (@cmd) = @_;
        my ($i) = grep { $cmd[$_] eq '--output_dir' } 0 .. $#cmd;
        $out_dir = $cmd[ $i + 1 ];
        return 1;    # whisper fails
    };

    eval { D2TG::Transcribe::transcribe( '/tmp/sample.oga', model => 'medium', runner => $runner ) };
    like( $@, qr/whisper failed/, 'transcribe dies clearly when whisper exits non-zero' );
    ok( !-d $out_dir, 'the whisper-output temp directory is removed even when whisper fails' );
}

{
    is( D2TG::Transcribe::_run( $^X, '-e', 'exit 0' ), 0, '_run returns 0 for a command that exits 0' );
    isnt( D2TG::Transcribe::_run( $^X, '-e', 'exit 3' ), 0, '_run returns non-zero for a command that exits non-zero' );
}

done_testing();
