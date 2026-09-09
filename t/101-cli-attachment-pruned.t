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

# TGT-134: an attachment's real file can be evicted later by
# D2TG::Download::prune_vault's own byte-cap eviction, even though its
# local_path stays in the DB forever - d2 tg.attachment's refusal
# message should say so specifically (ENOENT), not give the same
# generic message it gives for any other kind of open failure.

my $attachment_cli = File::Spec->catfile( $Bin, '..', 'cli', 'attachment.pl' );

sub _run_capturing_stderr {
    my (@cmd) = @_;
    my $err_file = "/tmp/d2tg-101-stderr.$$";
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
    close $fh;
    unlink $real_path;    # the file never actually exists - simulates a pruned attachment

    $store->record_message( 999, 42, 'ada', 'photo', local_path => $real_path );
    $store->disconnect;

    my ( $out, $rc, $err ) = _run_capturing_stderr( $attachment_cli, 999, 42 );

    isnt( $rc, 0, 'refuses when the stored file no longer exists' );
    like( $err, qr/pruned/i, 'the ENOENT-specific refusal names pruning as a likely cause' );
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

    my $a_directory = tempdir( CLEANUP => 1 );    # exists, but is not a readable file

    $store->record_message( 999, 43, 'ada', 'photo', local_path => $a_directory );
    $store->disconnect;

    my ( $out, $rc, $err ) = _run_capturing_stderr( $attachment_cli, 999, 43 );

    isnt( $rc, 0, 'refuses when the stored path cannot be opened as a file' );
    unlike( $err, qr/pruned/i, 'a non-ENOENT open failure gets the generic message, not the pruning-specific one' );
}

done_testing();
