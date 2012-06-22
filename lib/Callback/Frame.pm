package Callback::Frame;

use strict;

our $VERSION = '0.1';

require Exporter;
use base 'Exporter';
our @EXPORT = qw(frame fub);

use Scalar::Util;
use Carp qw/croak/;
use Guard;


our $top_of_stack;
our $active_frames = {};


sub frame {
  my ($name, $code, $catcher, $locals, $existing_frame);

  while ((my $k, my $v, @_) = @_) {
    if ($k eq 'name') {
      $name = $v;
    } elsif ($k eq 'code') {
      $code = $v;
    } elsif ($k eq 'catch') {
      $catcher = $v;
    } elsif ($k eq 'local') {
      $locals->{$v} = undef;
    } elsif ($k eq 'existing_frame') {
      $existing_frame = $v;
    } else {
      croak "Unknown frame option: $k";
    }

    croak "value missing for key $k" if !defined $v;
  }

  $name ||= 'ANONYMOUS FRAME';
  my ($package, $filename, $line) = caller;
  $name = "$filename:$line - $name";

  defined $code || croak "frame needs a 'code' callback";

  my $existing_top_of_stack;
  if (defined $existing_frame) {
    $existing_top_of_stack = $active_frames->{"$existing_frame"};
    croak "existing_frame isn't a frame" unless $existing_top_of_stack;
    croak "can't install new catcher if using existing_frame" if defined $catcher;
    croak "can't install new local if using existing_frame" if defined $locals;
  }


  my ($ret_cb, $internal_cb);

  $ret_cb = sub {
    return $internal_cb->(@_);
  };

  my $cb_address = "$ret_cb";

  my $new_frame;

  if ($existing_top_of_stack) {
    $new_frame = $existing_top_of_stack;
  } else {
    $new_frame = {
      name => $name,
      down => $top_of_stack,
      guard => guard {
        undef $ret_cb;
        delete $active_frames->{$cb_address};
      },
    };

    $new_frame->{catcher} = $catcher if defined $catcher;
    $new_frame->{locals} = $locals if defined $locals;

    $active_frames->{$cb_address} = $new_frame;
    Scalar::Util::weaken($active_frames->{$cb_address});
  }

  $internal_cb = sub {
    my $orig_error = $@;

    local $top_of_stack = $new_frame;

    my $frame_i = $top_of_stack;

    my $val = eval {
      ## Find applicable local vars

      my $local_refs = {};
      my $temp_copies = {};

      for(; $frame_i; $frame_i = $frame_i->{down}) {
        next unless exists $frame_i->{locals};
        foreach my $k (keys %{$frame_i->{locals}}) {
          next if exists $local_refs->{$k};
          $local_refs->{$k} = \$frame_i->{locals}->{$k};
        }
      }

      ## Backup local vars

      foreach my $var (keys %$local_refs) {
        no strict qw/refs/;
        $temp_copies->{$var} = $$var;
        $$var = ${$local_refs->{$var}};
      }

      ## Install code that will restore local vars

      scope_guard {
        foreach my $var (keys %$local_refs) {
          no strict qw/refs/;
          ${$local_refs->{$var}} = $$var;
          $$var = $temp_copies->{$var};
        }
      };

      ## Actually run the callback

      $@ = $orig_error;

      $code->(@_);
    };

    my $err = $@;

    if ($err) {
      my $trace = generate_trace($top_of_stack, $err);

      for (my $frame_i = $top_of_stack; $frame_i; $frame_i = $frame_i->{down}) {
        next unless exists $frame_i->{catcher};

        my $val = eval {
          $@ = $err;
          $frame_i->{catcher}->($trace);
          1
        };

        return if defined $val && $val == 1;

        $err = $@;
      }

      ## No catcher available: just re-throw error
      die $err;
    }

    return $val;
  };

  my $final_cb = $ret_cb;
  Scalar::Util::weaken($ret_cb);

  return $final_cb;
}


sub fub (&@) {
  my ($code, @args) = @_;

  return frame(code => $code, @args);
}


sub is_frame {
  my $coderef = shift;

  return 0 unless ref $coderef;

  return 1 if exists $active_frames->{$coderef};

  return 0;
}


sub generate_trace {
  my ($frame_pointer, $err) = @_;

  my $err_str = "$err";
  chomp $err_str;
  my $trace = "$err_str\n----- Callback::Frame stack-trace -----\n";

  for (my $frame_i = $frame_pointer; $frame_i; $frame_i = $frame_i->{down}) {
    $trace .= "$frame_i->{name}\n";
  }

  return $trace;
}



1;


__END__


=head1 NAME

Callback::Frame - Preserve error handlers and "local" variables across callbacks


=head1 SYNOPSIS

    use Callback::Frame;

    my $callback;

    frame(name => "base frame",
          code => sub {
                    $callback = frame(name => "frame #1",
                                      code => sub {
                                                die "some error";
                                              });
                  },
          catch => sub {
                     my $stack_trace = shift;
                     print $stack_trace;
                     ## Also, $@ is set to "some error at ..."
                   }
    )->();

    $callback->();

This will print something like:

    some error at synopsis.pl line 9.
    ----- Callback::Frame stack-trace -----
    synopsis.pl:10 - frame #1
    synopsis.pl:17 - base frame


=head1 BACKGROUND

When programming with callbacks in perl, you create anonymous functions with C<sub { ... }>. These functions are especially useful because when they are called they will preserve their surrounding lexical environment.

In other words, the following bit of code

    my $callback;
    {
      my $var = 123;
      $callback = sub { $var };
    }
    print $callback->();

will print C<123> even though C<$var> is no longer in scope when the callback is invoked.

Sometimes people call these anonymous functions that reference variables in their surrounding lexical scope "closures". Whatever you call them, they are essential for convenient and efficient asynchronous programming. 


=head1 DESCRIPTION

The problem that this module solves is that although closures preserve their lexical environment, they don't preserve their dynamic environment.

Consider the following piece of B<broken> code:

    use AnyEvent;

    eval { ## broken!
      $watcher = AE::timer 0.1, 0,
        sub {
          die "some error";
        };
    };

    if ($@) { ## broken!
      print STDERR "Oops: $@";
    }

    AE::cv->recv;

The intent behind the C<eval> above is obviously to catch any exceptions thrown inside the callback. However, this will not work because the C<eval> will only be in effect while installing the callback in the event loop, not while running it. When the event loop calls the callback, it will probably wrap its own C<eval> around the callback and you will see something like this:

    EV: error in callback (ignoring): some error at broken.pl line 6.

(The above applies to L<EV> which is a well-designed event loop. Other event loops may fail more catastrophically.)

So the root of the problem is that the dynamic environment has not been preserved. In this case it is the dynamic exception handlers that were not preserved. In some other cases we would like to preserve dynamically scoped (aka "local") variables (see below).

By the way, "lexical" and "dynamic" are the lisp terms and I use them because they actually make sense. When it applies to variables, perl confusingly calls dynamic scoping "local" scoping.

Here is how we could fix this code using L<Callback::Frame>:

    use AnyEvent;
    use Callback::Frame;

    frame(
      code => sub {
        $watcher = AE::timer 0.1, 0,
          frame(code => sub {
                          die "some error";
                        });
      }, catch => sub {
        print STDERR "Oops: $@";
      }
    )->();

    AE::cv->recv;

Now we see the desired error message:

    Oops: some error at fixed.pl line 8.

We created two frames to accomplish this: A root frame to contain the exception handler, and a nested frame to use as a callback. Because the nested callback frame is created while the root frame is executing, the callback will preserve the dynamic environment (including the exception handler) of the root frame.



=head1 USAGE

This module exports two functions, C<frame> and C<fub>.

C<frame> is the general interface and requires at least a C<code> argument which should be a coderef (a function or a closure). It will return another coderef that "wraps" the coderef you passed in. When this codref is run, it will re-instate the dynamic environment that was present when the frame was created, and then run the coderef that you passed in as C<code>.

B<IMPORTANT NOTE>: All callbacks that may be invoked outside the dynamic environment of the current frame should be created with C<frame> or C<fub> so that the dynamic environment will be correctly re-applied when the callback is invoked.

C<fub> is a wrapper around frame and exists to simplify converting existing callbacks into Callback::Frame enabled code. For example, given the following L<AnyEvent> statement:

    $watcher = AE::io $sock, 0, sub { do_stuff() };

In order for the callback to have its dynamic environment maintained, you just need to change it to this:

    $watcher = AE::io $sock, 0, fub { do_stuff() };

C<frame> and C<fub> both also accept C<catch> and C<local> parameters which are described in detail below.

If you wish to run a coderef inside an existing frame's dynamic environment, when creating a frame you can pass in an existing frame as the C<existing_frame> parameter. When this frame is executed, the C<code> of the frame will be run inside C<existing_frame>'s dynamic environment. This is useful for throwing exceptions from within some given callback's environment (timeouts for example) and for extracting/setting a callback's local variables.

Libraries that wrap callbacks in frames can use the C<Callback::Frame::is_frame()> function to determine if a given callback is already wrapped in a frame. It returns true if the callback is wrapped in a frame and is therefore suitable for use with C<existing_frame>.

You should never need to, but the internal frame stack can be accessed at C<$Callback::Frame::top_of_stack>. When this variable is defined, a frame is currently being executed.



=head1 NESTING AND STACK-TRACES

Frames can be nested. When an exception is raised, the most deeply nested C<catch> handler is invoked. If this handler itself throws an error, the next most deeply nested handler is invoked with the new exception but the original stack trace. If the last C<catch> handler re-throws the error, the error will simply be thrown to your application from wherever the callback happened to be called (probably not what you want).

When a C<catch> handler is called, not only is C<$@> set, but also a stack-trace string is passed in as the first argument. All frames will be listed in this stack-trace, starting with the most deeply nested frame.

If you want you can use simple frame names like C<"accepted"> but if you are recording error messages in a log you might find it useful to name your frames things like C<"accepted connection from $ip:$port at $time"> and C<"connecting to $host (timeout = $timeout seconds)">.

All frames you omit the name from will be shown as C<"ANONYMOUS FRAME"> in stack-traces.

One important thing to keep in mind is that frames aren't necessarily always arranged in terms of a stack. Really, frames are more of a tree data structure (known in lisp as a "spaghetti stack"). This occurs most often when two asynchronous request frames are started up concurrently while the same frame is in effect. At this point the "stack" has essentially branched. If you are ever surprised by an exception handler being called twice, this is probably what is happening.



=head1 "LOCAL" VARIABLES

In the same way that using C<catch> as described above preserves the dynamic environment of error handlers, C<local> preserves the dynamic environment of variables. Of course, the scope of these bindings is not actually local in the real sense of the word, only in the perl sense.

Technically, C<local> maintains the dynamic environment of B<bindings>. Although perl coders often ignore the distinction, lisp coders are careful to distinguish between variables and bindings. See, when a lexical binding is created, it is there "forever" -- or at least until it is no longer reachable by your program according to the rules of lexical scoping. Therefore, lexical variables are statically mapped to bindings and it is redundant to distinguish between lexical variables and bindings.

However, with dynamic variables the same variable can refer to different bindings at different times. That's why they are called "dynamic" and lexical variables are called "static".

Because any code in any file, function, or package can access a dynamic variable, they are the opposite of local. They are global. However, the bindings are only global for a little while at a time. After a while they will go out of scope and then they are no longer visible at all. Or sometimes they will get "shadowed" by some other binding and will come back again later.

OK, to make this concrete, after running this bit of code the binding containing C<2> is lost forever:

    our $foo = 1;
    my $cb;

    {
      local $foo;
      $foo = 2;
      $cb = sub {
        return $foo;
      };
    }

    say $foo;     # 1
    say $cb->();  # 1  <- not 2!
    say $foo;     # 1

Here's a way to "fix" that using Callback::Frame:

    our $foo = 1;
    my $cb;

    frame(local => __PACKAGE__ . '::foo',
          code => sub {
      $foo = 2;
      $cb = fub {
        return $foo;
      };
    })->();

    say $foo;     # 1
    say $cb->();  # 2  <- hooray!
    say $foo;     # 1

Don't be fooled into thinking that this is a lexical binding though. While the variable C<$foo> points to the binding containing C<2>, all parts of the program will see this binding:

    our $foo = 1;
    my $cb;

    sub global_foo_getter {
      return $foo;
    }

    frame(local => __PACKAGE__ . '::foo',
          code => sub {
      $foo = 2;
      $cb = fub {
        return global_foo_getter();
      };
    })->();

    say $foo;     # 1
    say $cb->();  # 2  <- still 2
    say $foo;     # 1


You can install multiple local variables in the same frame:

    frame(local => __PACKAGE__ . '::foo',
          local => 'main::bar',
          ... );

Note that if you have both C<catch> and C<local> elements in a frame, in the event of an error the local bindings will B<not> be present inside the C<catch> handler (use a nested frame if you need this).

All variable names must be fully package qualified. The best way to do this for variables in your current package is to use the ugly C<__PACKAGE__> technique.

Objects stored in local bindings managed by Callback::Frame will not be destroyed until all references to the frame-wrapped callback that contains the binding, along with all references to any deeper frames, are freed.



=head1 SEE ALSO

L<The Callback::Frame github repo|https://github.com/hoytech/Callback-Frame>

The Callback::Frame philosophy is that we actually like callback style and just want to simplify the reseting of dynamic environments as necessary. This module should make adding error handling support to an existing asynchronous application as easy as possible (it shouldn't force you to pass extra parameters around). Finally, this module should make lifer easier because as a side effect of adding error checking it should also produce detailed and useful stack traces.

This module's C<catch> syntax is of course modeled after "normal language" style exception handling as implemented by L<Try::Tiny> &c.

This module depends on L<Guard> to maintain the C<$Callback::Frame::active_frames> datastructure, and to ensure that even when exceptions are thrown, C<local> binding updates aren't lost.

L<AnyEvent::Debug> is a very interesting and useful module that provides an interactive debugger for AnyEvent applications and uses some of the same techniques that Callback::Frame does. L<AnyEvent::Callback> and L<AnyEvent::CallbackStack> sort of solve the dynamic error handler problem. Unlike these modules, Callback::Frame is not related at all to L<AnyEvent>, except that it happens to be useful in AnyEvent libraries and applications (among other things).

Miscellaneous other modules: L<IO::Lambda::Backtrace>, L<POE::Filter::ErrorProof>

Python Tornado's L<StackContext|http://www.tornadoweb.org/documentation/stack_context.html> and C<async_callback>

L<Let Over Lambda, Chapter 2|http://letoverlambda.com/index.cl/guest/chap2.html>

L<UNWIND-PROTECT vs. Continuations|http://www.nhplace.com/kent/PFAQ/unwind-protect-vs-continuations-original.html>



=head1 BUGS

For now, C<local> bindings can only be created in the scalar namespace. Also, none of the other nifty things that L<local> can do (like localising a hash table value) are supported yet.



=head1 AUTHOR

Doug Hoyte, C<< <doug@hcsw.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2012 Doug Hoyte.

This module is licensed under the same terms as perl itself.

=cut




TODO:

  * Maybe rewrite synopsis to use fub?
