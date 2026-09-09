use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use lib "$Bin/lib", "$Bin/../lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);

use D2TG::Config;
use D2TG::Store;

# TGT-133: d2 tg.attachment writes a downloaded attachment's raw bytes
# to stdout, never printing the real local filesystem path anywhere -
# the same never-expose-a-real-path convention this project's own Tira
# board follows for tira.attachment.get.

my $attachment_cli = File::Spec->catfile( $Bin, '..', 'cli', 'attachment.pl' );

sub _run_capturing_stderr {
    my (@cmd) = @_;
    my $err_file = "/tmp/d2tg-99-stderr.$$";
    my $out = `@cmd 2>$err_file`;
    my $rc  = $? >> 8;
    my $err = do { open my $fh, '<', $err_file or die $!; local $/; <$fh> };
    unlink $err_file;
    return ( $out, $rc, $err );
}

{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = '123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA';
    $ENV{D2TG_CHAT_ID} = '398296603';

    my $db_path = D2TG::Config::state_db_path(
        default_root => File::Spec->catdir( $Bin, '..' ),
        base_dir      => D2TG::Config::resolve_alias_dir( alias => undef ),
    );
    my $store = D2TG::Store->new( db_path => $db_path, admin_chat_id => 398296603 );

    my ( $fh, $real_path ) = tempfile( SUFFIX => '.jpg', UNLINK => 1 );
    binmode $fh;
    print {$fh} "not really a jpeg, just test bytes\x00\xff";
    close $fh;

    $store->record_message( 999, 42, 'ada', 'photo', local_path => $real_path );
    $store->disconnect;

    my ( $out, $rc, $err ) = _run_capturing_stderr( $attachment_cli, 999, 42 );

    is( $rc, 0, 'd2 tg.attachment exits 0 for a real recorded attachment' );
    is( $out, "not really a jpeg, just test bytes\x00\xff", 'stdout is exactly the original file bytes' );
    unlike( $err . $out, qr{\Q$real_path\E}, 'the real local filesystem path is never printed anywhere' );
}

{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = '123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA';
    $ENV{D2TG_CHAT_ID} = '398296603';

    my ( $out, $rc, $err ) = _run_capturing_stderr( $attachment_cli, 999, 9999 );

    isnt( $rc, 0, 'd2 tg.attachment refuses clearly for an unrecorded (chat_id, message_id)' );
    like( $err, qr/no attachment recorded/i, 'the refusal names the problem' );
}

{
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = '123456789:AAExampleTokenAAAAAAAAAAAAAAAAAAAAAAA';
    $ENV{D2TG_CHAT_ID} = '398296603';

    my ( $out, $rc, $err ) = _run_capturing_stderr( $attachment_cli, 'not-a-number', 42 );

    is( $rc, 2, 'd2 tg.attachment refuses a non-numeric chat_id with exit 2 (Usage)' );
    like( $err, qr/Usage/, 'the refusal names the Usage form' );
}

done_testing();
