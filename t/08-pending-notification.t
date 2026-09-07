use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempfile);

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

    my $first  = $store->add_pending(111);
    my $second = $store->add_pending(111);

    ok( $first,   'add_pending reports true the first time a chat id becomes pending' );
    ok( !$second, 'add_pending reports false when the chat id was already pending' );
}

done_testing();
