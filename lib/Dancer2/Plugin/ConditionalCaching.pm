use strictures 2;

package Dancer2::Plugin::ConditionalCaching;

# ABSTRACT: RFC7234 Caching

use Dancer2::Plugin;
use HTTP::Headers::Fancy;
use HTTP::Date qw(time2str str2time);
use HTTP::Exception;
use Scalar::Util qw(blessed);

# VERSION

sub _instanceof {
    my ($obj, @cls) = @_;
    return 0 unless blessed $obj;
    foreach my $cls (@cls) {
        return 1 if $obj->isa($cls);
    }
    return 0;
}

sub _cmp_weak {
    my ( $a, $b, $w ) = @_;
    return unless defined $a;
    return unless defined $b;
    $w //= 0;
    if ($w) {
        if ( ref $b ) {
            return $a eq $$b;
        }
        else {
            return $a eq $b;
        }
    }
    else {
        return 0 if ref $b;
        return $a eq $b;
    }
}

=head1 KEYWORDS

=head2 caching

=head3 Options

=over 4

=item * dry

Instead of exiting the current scope and starting the response immediately the estimated HTTP status code will be returned. The builder will not be called, the code 200 is returned instead.

=item * force

With CHI, the key will be removed before compute is called.

=item * throw

Instead of exiting the current scope and starting the response immediately a L<HTTP::Exception> will be thrown.

=item * check

When no check of the I<Cache-Control> request header is desired, set I<check> to C<0>.

=item * chi

An instance of L<CHI>.

=item * key

The name of the cache-key, only required when I<chi> is also given.

=item * object

Instead of set I<key>, I<changed>, I<expires> and/or I<builder> separately, a L<CHI::CacheObject> can be given here.

=item * changed

Timestamp when the data was last changed (or created). Default to current time.

=item * expires

Timestamp when the data is going to expire. Defaults to current time.

=item * builder

A CodeRef to a builder subroutine. Will be called when the data should be actually fetched from our database. With I<chi>, this subroutine will be passed to L<CHI/compute>.

=item * etag

An ETag to be checked against the request and to be send with the response. Defaults to I<key> param.

=item * weak

When the ETag is weak, set I<weak> to C<1>.

=item * cache

If the client should not be allowed to cache the response, set I<cache> to C<0>.

=item * store

If the client should not be allowed to store his cached data, set I<store> to C<0>.

=item * private

If the client should keep his cached data private (that means: not allowed to share the cached data between other stores), set I<private> to C<1>.

=item * public

If the client is explicity allowed to share the cached data with everyone, set I<public> to C<1>.

=item * 

=cut

register caching => sub {
    my $dsl  = shift;
    my %args = @_;

    #my $chi = delete $args{chi};
    #my $key = delete $args{key};
    my $dry = delete $args{dry} // 0;

    my $force = delete $args{force} // 0;
    my $throw = delete $args{throw} // 0;
    my $check = delete $args{check} // 1;

    #if ( _instanceof( $chi => 'CHI' ) and defined $key and not exists $args{object} ) {
    #    $args{object} = $chi->get_object( $key );
    #}

    #if ( _instanceof $args{object} => 'CHI::CacheObject' ) {
    #    my $co = delete $args{object};
    #    $args{key}     //= $co->key;
    #    $args{changed} //= $co->created_at;
    #    $args{expires} //= $co->expires_at;
    #    $args{builder} //= sub { $co->value };
    #}

    my $etag    = delete $args{etag}; #// $key;
    my $weak    = !!delete $args{weak};

    my $changed = delete $args{changed};
    my $expires = delete $args{expires};

    my $no_cache = ( ( delete $args{cache} // 1 ) == 0 );
    my $no_store = ( ( delete $args{store} // 1 ) == 0 );

    my $private = ( delete $args{private} // 0 );
    my $public  = ( delete $args{public}  // 0 );

    if ($private and $public) {
        warn "Cache-Control: private and public are mutually exclusive";
    }
    if ($no_cache) {
        if ($no_store) {
            warn "Cache-Control: no-cache and no-store are mutually exclusive";
        }
        if ($private) {
            warn "Cache-Control: no-cache and private are useless together";
        }
        if ($private) {
            warn "Cache-Control: no-cache and private are useless together";
        }
    }

    my %reqh = HTTP::Headers::Fancy::decode_hash( $dsl->request->headers );

    my %req_cc = HTTP::Headers::Fancy::split_field_hash( $reqh{CacheControl} );

    my $age   = time - int $changed if defined $changed;
    my $fresh = int $expires - time if defined $expires;

    if (defined $age and $age < 0) {
        warn("Age: changed points to a timestamp in future");
        $age = 0;
    }

    my %resp_cc = (
        ( NoCache => undef ) x !!$no_cache,
        ( NoStore => undef ) x !!$no_store,
        ( Private => undef ) x !!$private,
        ( Public  => undef ) x !!$public,
        MustRevalidate => undef,
        NoTransform    => undef,
    );

    if ($check) {
        if ( $req_cc{MaxAge} and defined $age ) {
            if ( $age > $req_cc{MaxAge} ) {
                $force = 1;
            }
        }

        if ( $req_cc{MinFresh} and defined $fresh ) {
            if ( $fresh < $req_cc{MinFresh} ) {
                $force = 1;
            }
        }
    }

    my $builder = sub {
        return unless defined $args{builder};
        my $sub;
        if ( ref $args{builder} eq 'CODE' ) {
            $sub = delete $args{builder};
        }
        else {
            my $data = delete $args{builder};
            $sub = sub { return $data };
        }
        my %subargs = (
            %req_cc,
            Force => $force,
        );
        #if ($chi and defined $expires) {
        #    $chi->remove($key) if $force;
        #    return $chi->compute(
        #        $key,
        #        { expires_at => $expires },
        #        sub { $sub->(%subargs) }
        #    );
        #} else {
            return $sub->(%subargs);
        #}
    };

    my %resph = (
        CacheControl => HTTP::Headers::Fancy::build_field_hash(%resp_cc),
        (Age          => $age) x!! defined($age),
        (Expires      => time2str($expires)) x!! defined($expires),
        ( Etag => ( $weak ? 'W/' : '' ) . '"' . ( $etag // '' ) . '"' ) x
          !!$etag,
        (LastModified => time2str($changed)) x!! defined($changed),
    );

    $dsl->response->header( HTTP::Headers::Fancy::encode_hash(%resph) ) unless $dry;

    if ($check) {
        my $if_match = ( exists $reqh{IfMatch} and defined $reqh{IfMatch} );
        my $if_match_any =
          ( $if_match and ( $reqh{IfMatch} =~ qr{^ \s* \* \s* $}xsi ) );
        my @if_match =
          $if_match_any
          ? ()
          : HTTP::Headers::Fancy::split_field_list( $reqh{IfMatch} );
    
        my $if_none_match =
          ( exists $reqh{IfNoneMatch} and defined $reqh{IfNoneMatch} );
        my $if_none_match_any =
          ( $if_none_match and ( $reqh{IfNoneMatch} =~ qr{^ \s* \* \s* $}xsi ) );
        my @if_none_match =
          $if_none_match_any ? ()
          : HTTP::Headers::Fancy::split_field_list( $reqh{IfNoneMatch} );
    
        my $if_modified_since   = str2time( $reqh{IfModifiedSince} );
        my $if_unmodified_since = str2time( $reqh{IfUnmodifiedSince} );
    
        if ($if_match) {
            unless ( ( $if_match_any and $etag )
                or ( grep { _cmp_weak( $etag, $_, $weak ) } @if_match ) )
            {
                HTTP::Exception->throw(412) if $throw;
                return 412 if $dry;
                $dsl->send_error( 'Precondition Failed', 412 );
            }
        }
        elsif ($if_unmodified_since and defined $changed ) {
            unless ( $if_unmodified_since > $changed ) {
                HTTP::Exception->throw(412) if $throw;
                return 412 if $dry;
                $dsl->send_error( 'Precondition Failed', 412 );
            }
        }
        if ($if_none_match) {
            if (   ( $if_none_match_any and $etag )
                or ( grep { _cmp_weak( $etag, $_, $weak ) } @if_none_match ) )
            {
                if ( $dsl->request->method =~ m{^(?:get|head)$}i ) {
                    HTTP::Exception->throw(304) if $throw;
                    return 304 if $dry;
                    $dsl->send_error( 'Not Modfied', 304 );
                }
                else {
                    HTTP::Exception->throw(412) if $throw;
                    return 412 if $dry;
                    $dsl->send_error( 'Precondition Failed', 412 );
                }
            }
        }
        elsif ( ( $dsl->request->method =~ m{^(?:get|head)$}i )
            and $if_modified_since and defined $changed )
        {
            if ( $if_modified_since > $changed ) {
                HTTP::Exception->throw(304) if $throw;
                return 304 if $dry;
                $dsl->send_error( 'Not Modfied', 304 );
            }
        }
    }

    if ($dry) {
        $builder->();
        return 200;
    }

    return $builder->();
};

register_plugin;

1;

=head1 SCENARIOS

The first three scenarious implicates that no impact in the response is desired. This is accomplished with the parameter I<check>, which should be set to C<0>.

=head2 Using Cache-Control only

Cache-Control is a mechanism to control a cache. In most cases that is not desired, i.e. the user have to make a request to get fresh data. The corrosponding header is called I<Cache-Control> and valid for both request and response. These paramerters control the header in the response:

=over 4

=item * cache

When C<0>, set I<no-cache>

=item * store

When I<0>, set I<no-store>

=item * public

When I<1>, set I<public>

=item * private

When I<1>, set I<private>

=back

I<no-cache> and I<no-store> are mutually exclusive. I<public> and I<private> and mutually exclusive, too.

I<no-cache> also eliminates I<no-store>, I<public> and I<private>.

To tell the client, not to cache the response, say:

    caching(check => 0, cache => 0);

To tell the client, not to store the response, say:

    caching(check => 0, store => 0);

To tell the client, sharing the response with everyone is okay, say:

    caching(check => 0, public => 1);

To tell the client, to keep the response private, say:

    caching(check => 0, private => 1);

The keywords I<must-revalidate> and I<no-transform> are sent with every response.

=head2 Using time-based headers only

There are three HTTP headers to indicate any time-based state of the response: I<Age>, I<Expires> and I<Last-Modified>.

I<Last-Modified> is redundant to I<Age>, but L<Last-Modified> represents an absolute timestamp whereas I<Age> represents a relative timestamp. Both are controlled by the same parameter.

=over 4

=item * changed

Accepts a timestamp and calculates I<Age> (I<now - changed>) and set I<Last-Modified> accordingly. Warns if the timestamp is in future - the resulting negative I<Age> value is forced to I<0>.

=item * expires

Accepts a timestamp and set I<Expires> accordingly. Values in the past are valid.

=back

To tell the client, the response expires in one hour, say:

    caching(check => 0, expires => time + 3600);
    
To tell the client, the data is created half an hour before, say:

    caching(check => 0, changed => time - 1800);

=head2 Using Etag

An I<Etag> is a counter, a checksum, an unique id, adressing a specific state of data. It's up to you what you provide.

The I<Etag> is taken from the parameter I<etag> and defaults to the parameter I<key>. The additional boolean parameter I<weak> indicates that the Etag is weak. Weak Etags compares to both weak and strong Etag whereas a strong Etag (i.e. non-weak Etag) compares only to strong Etags. If you don't know what that means, don't think about it. The Etag is strong by default and that's okay.

To tell the client, the response has the Etag C<abcdef>, say:

    caching(check => 0, etag => 'abcdef');

=head2 Answer a GET or HEAD conditional request

This step is basically accomplished by omitting the I<check> parameter in the examples above. It compares the request headers and then decides to answer the request with I<304 Not Modified> status code.

A compare against the Etag takes precedence over time-based constraints. Etags are comapre with the I<If-None-Match> request header, time-based constraints are compared with the I<If-Modified-Since> request header.

To check against the Etag C<abcdef>, and exit the current route with I<304> if the Etag matches, say:

    caching(etag => 'abcdef');

To check against time-based constraints, say:

    caching(changed => time - 3600);

=head2 Answer a POST, PUT, PATCH or DELETE conditional request

Its not really different to the example above. In case of a conflict, the status code is I<412 Precondition Failed>. Etags are compared aginst I<If-Match> and time-based constraints are compared against I<If-Unmodified-Since>.

=head2 Going deeper: using helper subroutine

It's possible that a client may request a state, which should not expire within a specific amount of time. That is accomplished via the I<min-fresh> field inside the I<Cache-Control> request header. And/or the client may also request a state, which is not older than a specific amount of time. That's accomplished via the I<max-age> field in the I<Cache-Control> request header. Both values are compared with I<created> and I<expires>, and the variable I<force> will be set to accordingly. To access that variable, a builder subroutine can be used, which passes some additionals information:

    caching(builder => sub {
        %opts = @_;
        # requested max-age
        $maxage = $opts{MaxAge};
        # requested min-fresh
        $minfresh = $opts{MinFresh};
        # automatically calculated
        $force = $opts{Force};
    });

I<Force> is C<0> by default. When I<max-age> is less than the current age of the data, or when I<min-fresh> is greather than the current freshness (time in seconds till the state expires), then I<Force> is C<1>.

The result of I<builder> is returned by I<caching>.

    $one_two_three = caching(builder => sub {
        return 123;
    })

If I<builder> is not a CodeRef, the value of that will be returned instead.

    $four_five_six = caching(builder => 456);

=head2 Dry and catch

If you don't want any headers to be set, no exception to be thrown and no auto-exit of the current route, then set I<dry> to C<1>.

    $status_code = caching(dry => 1);

And if you just don't want the auto-exit of the current route, but a L<HTTP::Exception> to be thrown, set I<throw> to I<1>

    eval {
        caching(throw => 1);
    };
    if (my $e = HTTP::Exception->caught) {
        $status_code = $e->code; # 304 or 412
    }
