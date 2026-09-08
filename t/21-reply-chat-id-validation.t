use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

my $reply_cli = File::Spec->catfile( $Bin, '..', 'cli', 'reply' );

use File::Temp qw(tempdir);
use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);
setup_mandatory_db_env( $Bin, tempdir( CLEANUP => 1 ) );

{
    my $out = `$reply_cli abc hello 2>/tmp/d2tg-reply-stderr.$$`;
    my $rc  = $? >> 8;
    my $err = do { open my $fh, '<', "/tmp/d2tg-reply-stderr.$$" or die $!; local $/; <$fh> };
    unlink "/tmp/d2tg-reply-stderr.$$";

    is( $rc, 2, 'cli/reply exits 2 for a non-numeric chat_id' );
    like( $err, qr/Usage/, 'cli/reply reports a Usage message on STDERR for a non-numeric chat_id' );
    unlike( $out, qr/Replied to/, 'cli/reply never claims to have replied for a rejected chat_id' );
}

{
    my $out = `$reply_cli 2>/tmp/d2tg-reply-stderr2.$$`;
    my $rc  = $? >> 8;
    my $err = do { open my $fh, '<', "/tmp/d2tg-reply-stderr2.$$" or die $!; local $/; <$fh> };
    unlink "/tmp/d2tg-reply-stderr2.$$";

    is( $rc, 2, 'cli/reply with no arguments still exits 2 (unchanged too-few-args behavior)' );
    like( $err, qr/Usage/, 'cli/reply still reports the too-few-args Usage message on STDERR' );
}

{
    my $out = `$reply_cli 123456 2>/tmp/d2tg-reply-stderr3.$$`;
    my $rc  = $? >> 8;
    my $err = do { open my $fh, '<', "/tmp/d2tg-reply-stderr3.$$" or die $!; local $/; <$fh> };
    unlink "/tmp/d2tg-reply-stderr3.$$";

    is( $rc, 2, 'cli/reply with a numeric chat_id but no text still exits 2 (unchanged too-few-args behavior)' );
    like( $err, qr/Usage/, 'still the too-few-args Usage message, not a chat_id-rejection message' );
}

{
    my $out = `$reply_cli 123456 hello --reply-to-message-id abc 2>/tmp/d2tg-reply-stderr4.$$`;
    my $rc  = $? >> 8;
    my $err = do { open my $fh, '<', "/tmp/d2tg-reply-stderr4.$$" or die $!; local $/; <$fh> };
    unlink "/tmp/d2tg-reply-stderr4.$$";

    is( $rc, 2, 'cli/reply exits 2 for a non-numeric --reply-to-message-id (TGT-040)' );
    like( $err, qr/Usage/, 'cli/reply reports a Usage message on STDERR for a non-numeric --reply-to-message-id' );
    unlike( $out, qr/Replied to/, 'cli/reply never claims to have replied for a rejected --reply-to-message-id' );
}

done_testing();
