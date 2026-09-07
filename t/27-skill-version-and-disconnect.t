use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Spec;

require D2TG::Config;
require D2TG::Store;

{
    my $skill_root = tempdir( CLEANUP => 1 );
    open my $fh, '>', File::Spec->catfile( $skill_root, '.env' ) or die $!;
    print {$fh} "VERSION=0.42\n";
    close $fh;

    is( D2TG::Config::skill_version( default_root => $skill_root ), '0.42', 'skill_version reads VERSION from .env' );
}

{
    my $skill_root = tempdir( CLEANUP => 1 );
    open my $fh, '>', File::Spec->catfile( $skill_root, '.env' ) or die $!;
    print {$fh} "SOMETHING_ELSE=1\n";
    close $fh;

    eval { D2TG::Config::skill_version( default_root => $skill_root ) };
    like( $@, qr/VERSION/, 'skill_version dies clearly when .env has no VERSION line' );
}

{
    my $skill_root = tempdir( CLEANUP => 1 );

    eval { D2TG::Config::skill_version( default_root => $skill_root ) };
    like( $@, qr/\.env/, 'skill_version dies clearly when .env is missing entirely' );
}

{
    my ( $fh, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    close $fh;
    unlink $db;

    my $store = D2TG::Store->new( db_path => $db, admin_chat_id => 1 );
    ok( $store->{dbh}->ping, 'the dbh is alive before disconnect' );

    $store->disconnect;

    ok( !$store->{dbh}->ping, 'the dbh is no longer alive after disconnect' );
}

done_testing();
