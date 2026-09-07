use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Spec;
use File::Temp qw(tempfile tempdir);

require D2TG::Store;

sub fresh_db_path {
    my ( $fh, $path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    close $fh;
    unlink $path;
    return $path;
}

{
    my $db = fresh_db_path();
    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );
    $store->add_pending(111);

    my $result = $store->approve(111);

    ok( $result, 'approve returns a true result for a genuinely pending chat id' );
    ok( $store->is_allowed(111), 'the chat id is now allow-listed' );
    is_deeply( [ $store->pending_chat_ids ], [], 'the chat id is no longer pending' );
}

{
    my $db = fresh_db_path();
    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );

    my $result = $store->approve(222);

    ok( !$result, 'approve returns false for a chat id that was never pending' );
    ok( !$store->is_allowed(222), 'it is not allow-listed either' );
}

{
    my $db = fresh_db_path();
    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );
    $store->add_pending(333);
    $store->approve(333);

    my $result = $store->approve(333);

    ok( !$result, 'approving an already-approved chat id a second time reports false (idempotent, not an error)' );
    ok( $store->is_allowed(333), 'it remains allow-listed' );
}

{
    my $approve_cli = File::Spec->catfile( $Bin, '..', 'cli', 'approve' );
    my $skill_root  = tempdir( CLEANUP => 1 );

    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}                     = 'test-token';
    $ENV{D2TG_CHAT_ID}                   = '999';
    $ENV{DEVELOPER_DASHBOARD_SKILL_ROOT} = $skill_root;

    my $db_path = File::Spec->catfile( $skill_root, 'state', 'store.sqlite' );
    require File::Path;
    File::Path::make_path( File::Spec->catdir( $skill_root, 'state' ) );
    D2TG::Store->new( db_path => $db_path, admin_chat_id => 999 )->add_pending(444);

    my $out = `$approve_cli 444 2>/tmp/d2tg-approve-stderr.$$`;
    my $rc  = $? >> 8;
    unlink "/tmp/d2tg-approve-stderr.$$";

    is( $rc, 0, 'cli/approve exits 0 for a genuinely pending chat id' );
    like( $out, qr/Approved 444/, 'cli/approve confirms the approval' );

    my $out2 = `$approve_cli 555 2>/tmp/d2tg-approve-stderr2.$$`;
    my $rc2  = $? >> 8;
    my $err2 = do { open my $fh, '<', "/tmp/d2tg-approve-stderr2.$$" or die $!; local $/; <$fh> };
    unlink "/tmp/d2tg-approve-stderr2.$$";

    isnt( $rc2, 0, 'cli/approve exits non-zero for a chat id that was never pending' );
    like( $err2, qr/never pending/i, 'cli/approve reports the failure clearly on STDERR' );

    my $out3 = `$approve_cli 2>/tmp/d2tg-approve-stderr3.$$`;
    my $rc3  = $? >> 8;
    unlink "/tmp/d2tg-approve-stderr3.$$";
    isnt( $rc3, 0, 'cli/approve with no argument exits non-zero' );

    D2TG::Store->new( db_path => $db_path, admin_chat_id => 999 )->add_pending(666);

    my $out4 = `$approve_cli 666 junk 2>/tmp/d2tg-approve-stderr4.$$`;
    my $rc4  = $? >> 8;
    unlink "/tmp/d2tg-approve-stderr4.$$";
    isnt( $rc4, 0, 'cli/approve with a stray extra argument is refused rather than silently ignoring it' );

    my $store_check = D2TG::Store->new( db_path => $db_path, admin_chat_id => 999 );
    ok( !$store_check->is_allowed(666),
        '...and the chat id named before the stray argument was NOT approved as a side effect' );

    # 444 was approved above, so it is now allow-listed but not pending -
    # re-approving it should read differently from an id never seen at all.
    my $out5 = `$approve_cli 444 2>/tmp/d2tg-approve-stderr5.$$`;
    my $rc5  = $? >> 8;
    my $err5 = do { open my $fh, '<', "/tmp/d2tg-approve-stderr5.$$" or die $!; local $/; <$fh> };
    unlink "/tmp/d2tg-approve-stderr5.$$";

    isnt( $rc5, 0, 're-approving an already-allowed chat id still exits non-zero (no state change happened)' );
    like( $err5, qr/already allowed/i, 'but the message distinguishes "already allowed" from "never seen"' );

    my $out6 = `$approve_cli 777 2>/tmp/d2tg-approve-stderr6.$$`;
    my $err6 = do { open my $fh, '<', "/tmp/d2tg-approve-stderr6.$$" or die $!; local $/; <$fh> };
    unlink "/tmp/d2tg-approve-stderr6.$$";

    like( $err6, qr/never/i, 'a genuinely unknown chat id gets the distinct "never seen" wording' );
    unlike( $err6, qr/already allowed/i, '...and not the "already allowed" wording' );
}

{
    my $db = fresh_db_path();
    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );
    $store->add_pending(888);

    my $real_do = \&DBI::db::do;
    my ( $result, $error );
    {
        no warnings 'redefine';
        local *DBI::db::do = sub {
            my ( $self, $sql, @rest ) = @_;
            die "simulated transient DB error\n"
              if $sql =~ /INSERT OR IGNORE INTO allow_list/;
            return $real_do->( $self, $sql, @rest );
        };

        $result = eval { $store->approve(888) };
        $error  = $@;
    }

    ok( !$result || $error, 'approve() does not silently succeed when the transaction fails mid-way' );

    # Whether it died or returned false, the transaction must not be left
    # open - a fresh approve() call on the SAME Store object must still work.
    $store->add_pending(999);
    my $result2 = eval { $store->approve(999) };
    my $error2  = $@;

    ok( $result2, 'a subsequent approve() call on the same Store object succeeds (no dangling transaction)' )
      or diag("error2: $error2");
    ok( $store->is_allowed(999), 'and the chat id it approved is genuinely allow-listed' );
}

done_testing();
