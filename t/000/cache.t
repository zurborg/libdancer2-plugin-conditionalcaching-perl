#!perl -T

use lib '.';
use t::tests;

#plan tests => 2;

{

    package Webservice;
    use Dancer2;
    use Dancer2::Plugin::ConditionalCaching;
    use File::Temp qw(tempdir);
    use CHI;

    my $dir = tempdir( CLEANUP => 1 );
    our $chi = CHI->new( driver => 'File', root_dir => $dir );

    get '/a' => sub {
        $chi->compute( 123, '5min', sub { time } );
        return caching(
            chi => $chi,
            key => 123,
        );
    };

    get '/b' => sub {
        return caching(
            chi     => $chi,
            key     => 456,
            expires => time + 12345,
            builder => sub { time },
        );
    };

}

my $PT = boot 'Webservice';

dotest(
    a => 3,
    sub {
        my $R;
        my $t = measure(
            sub {
                $R = request( $PT, GET => '/a' );
            }
        );
        ok $R->is_success;
        approx( time, $t )->( $R->content );
        testh( $R, Expires => approx_httpdate( time + 300, $t ), );
    }
);

for ( my $i = 5 ; $i > 0 ; $i-- ) {
    diag "wait for $i secs...";
    sleep 1;
}

dotest(
    a => 3,
    sub {
        my $R;
        my $t = measure(
            sub {
                $R = request( $PT, GET => '/a' );
            }
        );
        ok $R->is_success;
        approx( time - 5, $t )->( $R->content );
        testh( $R, LastModified => approx_httpdate( time - 5, $t ), );
    }
);

dotest(
    b => 3,
    sub {
        my $R;
        my $t = measure(
            sub {
                $R = request( $PT, GET => '/b' );
            }
        );
        ok $R->is_success;
        approx( time, $t )->( $R->content );
        testh( $R, Expires => approx_httpdate( time + 12345, $t ), );
    }
);

done_testing();
