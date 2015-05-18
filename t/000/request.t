#!perl -T

use lib '.';
use t::tests;

plan tests => 2;

{

    package Webservice;
    use Dancer2;
    use Dancer2::Plugin::ConditionalCaching;

    get '/a' => sub {
        return caching( builder => sub { to_dumper( {@_} ) } );
    };

}

my $PT = boot 'Webservice';

dotest(
    a1 => 2,
    sub {
        my $R;
        my $t = measure(
            sub {
                $R = request( $PT, GET => '/a' );
            }
        );
        ok $R->is_success;
        my $C = deserialize($R);
        is_deeply $C => {
            Force => 0,
        };
    }
);

dotest(
    a2 => 2,
    sub {
        my $R;
        my $t = measure(
            sub {
                $R = request(
                    $PT,
                    GET => '/a',
                    headers(
                        CacheControl => {
                            MaxAge   => 12345,
                            MinFresh => 67890,
                        }
                    ),
                );
            }
        );
        ok $R->is_success;
        my $C = deserialize($R);
        is_deeply $C => {
            MaxAge   => 12345,
            MinFresh => 67890,
            Force => 1,
        };
    }
);

done_testing();
