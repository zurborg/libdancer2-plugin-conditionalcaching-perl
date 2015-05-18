#!perl -T

use lib '.';
use t::tests;

plan tests => 6;

{

    package Webservice;
    use Dancer2;
    use Dancer2::Plugin::ConditionalCaching;

    get '/a' => sub {
        caching();
    };

    get '/b1' => sub {
        caching( etag => 123 );
    };

    get '/b2' => sub {
        caching( etag => 123, weak => 1 );
    };

    get '/c' => sub {
        caching( changed => ( time - 12345 ) );
    };

    get '/d' => sub {
        caching( expires => ( time + 12345 ) );
    };

    get '/e' => sub {
        caching( cache => 0, store => 0, public => 1, private => 1 );
    };
}

my $PT = boot 'Webservice';

dotest(
    a => 2,
    sub {
        my $R;
        my $t = measure(
            sub {
                $R = request $PT, GET => '/a';
            }
        );
        ok $R->is_success;
        testh(
            $R,
            Expires      => qr{},
            CacheControl => qr{},
            Age          => approx( 0, $t ),
            LastModified => qr{},
        );
    }
);

dotest(
    b1 => 2,
    sub {
        my $R;
        my $t = measure(
            sub {
                $R = request $PT, GET => '/b1';
            }
        );
        ok $R->is_success;
        testh( $R, Etag => '"123"', );
    }
);

dotest(
    b2 => 2,
    sub {
        my $R;
        my $t = measure(
            sub {
                $R = request $PT, GET => '/b2';
            }
        );
        ok $R->is_success;
        testh( $R, Etag => 'W/"123"', );
    }
);

dotest(
    c => 2,
    sub {
        my $R;
        my $t = measure(
            sub {
                $R = request $PT, GET => '/c';
            }
        );
        ok $R->is_success;
        testh(
            $R,
            Expires      => approx_httpdate( time,         $t ),
            Age          => approx( +12345,                $t ),
            LastModified => approx_httpdate( time - 12345, $t ),
        );
    }
);

dotest(
    d => 2,
    sub {
        my $R;
        my $t = measure(
            sub {
                $R = request $PT, GET => '/d';
            }
        );
        ok $R->is_success;
        testh(
            $R,
            Expires      => approx_httpdate( time + 12345, $t ),
            Age          => approx( 0,                     $t ),
            LastModified => approx_httpdate( time,         $t ),
        );
    }
);

dotest(
    e => 2,
    sub {
        my $R;
        my $t = measure(
            sub {
                $R = request $PT, GET => '/e';
            }
        );
        ok $R->is_success;
        testh(
            $R,
            CacheControl => testfs(
                MustRevalidate => qr{},
                NoTransform    => qr{},
                NoCache        => qr{},
                NoStore        => qr{},
                Public         => qr{},
                Private        => qr{},
            ),
        );
    }
);

done_testing();
