use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use Test::CaptureStdio qw(capture_stdio);

require D2TG::Transcribe;

{
    local $D2TG::Transcribe::TIMEOUT = 10;

    my ( $result, $captured_out, $captured_err ) = capture_stdio( sub {
        return D2TG::Transcribe::_run(
            $^X, '-e',
            'print "chatty stdout line\n"; print STDERR "chatty stderr line\n"; exit 0;'
        );
    } );

    is( $result->[0], 0, '_run still returns 0 for a command that exits 0' );
    is( $captured_out, '', "the child's own stdout never reaches the real stdout" );
    is( $captured_err, '', "the child's own stderr never reaches the real stderr" );
}

done_testing();
