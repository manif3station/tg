use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Spec;
use File::Temp qw(tempdir);

# TGT-090 (live user request + live reproduction): TIRA_HOME (or a
# resolved --db/-d/D2TG_DB alias) naming a directory that does not yet
# exist must never be silently created - every d2 tg.* command must
# refuse to start instead. Confirmed live in a tira:latest container
# before this fix: TIRA_HOME=foobar (a bogus, nonexistent relative path)
# caused `d2 tg.unread` to silently mkdir -p ./foobar/.tira/ and create
# telegram.messages.db inside it.

require D2TG::Config;

{
    my $dir       = tempdir( CLEANUP => 1 );
    my $ghost_dir = File::Spec->catdir( $dir, 'does-not-exist-yet' );

    eval { D2TG::Config::require_existing_base_dir($ghost_dir) };
    like( $@, qr/\Q$ghost_dir\E/, 'require_existing_base_dir dies naming a nonexistent directory' );
    like( $@, qr/does not exist/i, 'the message says the directory does not exist' );
    ok( !-e $ghost_dir, 'the nonexistent directory was NOT created as a side effect' );
}

{
    my $dir = tempdir( CLEANUP => 1 );
    my $returned = D2TG::Config::require_existing_base_dir($dir);
    is( $returned, $dir, 'require_existing_base_dir returns the base_dir unchanged when it already exists' );
}

# --- real cli/* subprocess integration: TIRA_HOME pointing to a
# --- nonexistent directory must refuse and create nothing, for every
# --- command that resolves a base_dir ---
{
    my $work_dir = tempdir( CLEANUP => 1 );

    for my $name (qw(unread history approve)) {
        my $cli = File::Spec->catfile( $Bin, '..', 'cli', $name );

        local %ENV = %ENV;
        delete $ENV{D2TG_DB};
        $ENV{TIRA_HOME} = File::Spec->catdir( $work_dir, "ghost-$name" );
        my @extra_args = $name eq 'approve' ? ('12345') : ();

        my $out = `"$^X" "$cli" @extra_args 2>&1`;
        my $rc  = $? >> 8;

        isnt( $rc, 0, "d2 tg.$name refuses when TIRA_HOME names a nonexistent directory" );
        ok( !-e $ENV{TIRA_HOME}, "d2 tg.$name did not create the TIRA_HOME directory ($name)" );
    }
}

done_testing();
