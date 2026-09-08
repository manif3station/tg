use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use File::Temp qw(tempfile tempdir);
use File::Spec;
use DBI;
use Test::MandatoryDb qw(setup_mandatory_db_env);

require D2TG::Store;
require D2TG::Config;

# TGT-098 (bug-hunt finding, Michael's answer Q-008): allow_list/pending
# used to be keyed only by chat_id, no bot dimension - a Telegram GROUP
# chat shared by two of this skill's configured bots has the SAME
# chat_id for both bots, so approving it for one bot silently also
# approved it for the other. Now scoped by (chat_id, bot_key), with ''
# as the single-bot/unscoped sentinel.

{
    my ( $fh, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    close $fh;
    unlink $db;

    my $store = D2TG::Store->new( db_path => $db );

    ok( $store->add_pending( 555, 'tokenA' ), 'add_pending under tokenA' );
    ok( $store->approve( 555, 'tokenA' ), 'approve under tokenA' );

    ok( $store->is_allowed( 555, 'tokenA' ), 'is_allowed(555, tokenA) is true - approved under this bot' );
    ok( !$store->is_allowed( 555, 'tokenB' ), 'is_allowed(555, tokenB) is FALSE - the exact leak this ticket closes' );
}

{
    # Single-bot mode (bot_key omitted everywhere) must behave exactly
    # as before this ticket.
    my ( $fh, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    close $fh;
    unlink $db;

    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );

    ok( $store->is_allowed(999), 'admin_chat_id is seeded and allowed with no bot_key given (single-bot mode unchanged)' );

    $store->add_pending(111);
    ok( $store->approve(111), 'approve with no bot_key still works' );
    ok( $store->is_allowed(111), 'is_allowed with no bot_key still works' );
}

{
    # Migration: a pre-existing single-column-PK allow_list/pending
    # (the schema before this ticket) must survive being opened by the
    # new code - existing rows preserved, bot_key defaults to ''.
    my ( $fh, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    close $fh;
    unlink $db;

    my $dbh = DBI->connect( "dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, AutoCommit => 1 } );
    $dbh->do('CREATE TABLE allow_list (chat_id INTEGER PRIMARY KEY)');
    $dbh->do('CREATE TABLE pending (chat_id INTEGER PRIMARY KEY)');
    $dbh->do('INSERT INTO allow_list (chat_id) VALUES (777)');
    $dbh->do('INSERT INTO pending (chat_id) VALUES (888)');
    $dbh->disconnect;

    my $store = D2TG::Store->new( db_path => $db );

    ok( $store->is_allowed(777), 'a pre-migration allow_list row survives the migration and is still allowed (bot_key defaults to empty)' );

    my $cols = $store->{dbh}->selectall_arrayref( 'PRAGMA table_info(allow_list)', { Slice => {} } );
    ok( ( grep { $_->{name} eq 'bot_key' } @$cols ), 'allow_list gained a bot_key column after migration' );

    ok( $store->approve(888), 'a pre-migration pending row survives the migration and can still be approved' );
    ok( $store->is_allowed(888), 'the migrated-then-approved chat id is allowed' );
}

{
    # The migration is wrapped in a transaction (SQLite DDL is
    # transactional) so a failure mid-migration can never leave the old
    # data orphaned in a renamed-aside table while a fresh, empty
    # new-shape table silently appears on the next run instead of being
    # noticed. Simulated here by making the INSERT (the data-copy step)
    # fail.
    my ( $fh, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    close $fh;
    unlink $db;

    my $dbh = DBI->connect( "dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, AutoCommit => 1 } );
    $dbh->do('CREATE TABLE allow_list (chat_id INTEGER PRIMARY KEY)');
    $dbh->do('CREATE TABLE pending (chat_id INTEGER PRIMARY KEY)');
    $dbh->do('INSERT INTO allow_list (chat_id) VALUES (999)');
    $dbh->disconnect;

    my $real_do = \&DBI::db::do;
    my $error;
    {
        no warnings 'redefine';
        local *DBI::db::do = sub {
            my ( $self, $sql, @rest ) = @_;
            die "simulated failure mid-migration\n"
              if $sql =~ /INSERT INTO allow_list \(chat_id, bot_key\)/;
            return $real_do->( $self, $sql, @rest );
        };

        eval { D2TG::Store->new( db_path => $db ) };
        $error = $@;
    }

    like( $error, qr/simulated failure mid-migration/, 'a mid-migration failure propagates loudly (dies) rather than silently continuing' );

    # Re-open with the real (unmocked) code - the transaction rollback
    # means the migration retries cleanly from the original, unmodified
    # pre-migration state, not a half-migrated one.
    my $store = D2TG::Store->new( db_path => $db );
    ok( $store->is_allowed(999), 'after the simulated failure, a real re-open still migrates successfully and the original row survives (proves the rollback left no half-migrated state)' );
}

{
    # cli/approve --bot <token> scopes the approval; cli/approve with no
    # --bot approves under the single-bot sentinel.
    my $approve_cli = File::Spec->catfile( $Bin, '..', 'cli', 'approve.pl' );
    my $skill_root  = tempdir( CLEANUP => 1 );

    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}                     = 'test-token';
    $ENV{D2TG_CHAT_ID}                   = '999';
    $ENV{DEVELOPER_DASHBOARD_SKILL_ROOT} = $skill_root;

    setup_mandatory_db_env( $Bin, $skill_root );

    my $db_path = D2TG::Config::state_db_path( base_dir => $skill_root );
    my $seed_store = D2TG::Store->new( db_path => $db_path, admin_chat_id => 999 );
    $seed_store->add_pending( 1000, 'tokenA' );

    my $out = `$approve_cli --bot tokenA 1000 2>/tmp/d2tg-approve-bot-stderr.$$`;
    my $rc  = $? >> 8;
    unlink "/tmp/d2tg-approve-bot-stderr.$$";

    is( $rc, 0, 'cli/approve --bot tokenA 1000 exits 0' );
    like( $out, qr/Approved 1000/, 'cli/approve --bot confirms the approval' );

    my $check_store = D2TG::Store->new( db_path => $db_path, admin_chat_id => 999 );
    ok( $check_store->is_allowed( 1000, 'tokenA' ), 'approved under tokenA is allowed under tokenA' );
    ok( !$check_store->is_allowed( 1000, 'tokenB' ), 'approved under tokenA is NOT allowed under tokenB' );
}

done_testing();
