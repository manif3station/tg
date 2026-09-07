use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempfile);

require D2TG::TTS;

{
    my ( $out_fh, $out_path ) = tempfile( UNLINK => 1 );
    my ( $err_fh, $err_path ) = tempfile( UNLINK => 1 );

    open my $saved_stdout, '>&', \*STDOUT or die $!;
    open my $saved_stderr, '>&', \*STDERR or die $!;
    open STDOUT, '>&', $out_fh or die $!;
    open STDERR, '>&', $err_fh or die $!;

    my $rc = D2TG::TTS::_run(
        $^X, '-e',
        'print "chatty stdout line\n"; print STDERR "chatty stderr line\n"; exit 0;'
    );

    open STDOUT, '>&', $saved_stdout or die $!;
    open STDERR, '>&', $saved_stderr or die $!;

    is( $rc, 0, '_run still returns 0 for a command that exits 0' );

    close $out_fh;
    close $err_fh;
    open my $out_read, '<', $out_path or die $!;
    open my $err_read, '<', $err_path or die $!;
    local $/;
    my $captured_out = <$out_read>;
    my $captured_err = <$err_read>;

    is( $captured_out, '', "the child's own stdout never reaches the real stdout" );
    is( $captured_err, '', "the child's own stderr never reaches the real stderr" );
}

{
    isnt( D2TG::TTS::_run( $^X, '-e', 'exit 3' ), 0, '_run still returns non-zero for a command that exits non-zero' );
}

done_testing();
