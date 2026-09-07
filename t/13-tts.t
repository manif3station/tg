use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::TTS;

{
    eval { D2TG::TTS::synthesize('') };
    like( $@, qr/must not be empty/, 'synthesize dies on empty text' );
}

{
    my @calls;
    my $runner = sub { push @calls, [@_]; return 0; };

    my $path = D2TG::TTS::synthesize( 'hello world', runner => $runner );

    is( scalar @calls, 2, 'exactly two commands are run: gtts then ffmpeg' );
    like( $calls[0][0], qr/gtts/,   'the first command invokes gtts' );
    like( $calls[1][0], qr/ffmpeg/, 'the second command invokes ffmpeg' );
    like( $path, qr/\.ogg$/, 'synthesize returns a path to an .ogg file' );
    ok( -e $path, 'the returned ogg path exists' );

    unlink $path;
}

{
    my @calls;
    my $runner = sub { push @calls, [@_]; return 1; };    # gtts fails

    eval { D2TG::TTS::synthesize( 'hello', runner => $runner ) };
    like( $@, qr/gtts-cli failed/, 'synthesize dies when the gtts step fails' );
    is( scalar @calls, 1, 'ffmpeg is never invoked once the gtts step has already failed' );
}

{
    my $calls = 0;
    my $runner = sub {
        $calls++;
        return $calls == 1 ? 0 : 1;    # gtts succeeds, ffmpeg fails
    };

    eval { D2TG::TTS::synthesize( 'hello', runner => $runner ) };
    like( $@, qr/ffmpeg conversion/, 'synthesize dies when the ffmpeg conversion step fails' );
    is( $calls, 2, 'both steps were attempted before the failure was raised' );
}

{
    is( D2TG::TTS::_run( $^X, '-e', 'exit 0' ), 0, '_run returns 0 for a command that exits 0' );
    isnt( D2TG::TTS::_run( $^X, '-e', 'exit 3' ), 0, '_run returns non-zero for a command that exits non-zero' );
}

done_testing();
