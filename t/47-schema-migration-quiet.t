use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use Test::CaptureStdio qw(capture_stdio);

require D2TG::Store;

{
    my ( undef, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );

    # First open: creates the schema fresh, including the ALTER TABLE add.
    my $store1 = D2TG::Store->new( db_path => $db, admin_chat_id => 999 );

    # Second open against the SAME already-migrated database: this is
    # exactly what happens on every poller restart (TGT-036) or every
    # additional D2TG::Store->new() call in the same process.
    my ( undef, undef, $stderr ) = capture_stdio( sub {
        D2TG::Store->new( db_path => $db, admin_chat_id => 999 );
    } );

    is( $stderr, '', 'opening an already-migrated database prints nothing to STDERR' );
}

done_testing();
