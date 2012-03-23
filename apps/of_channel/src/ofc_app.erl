%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Krzysztof Rutka <krzysztof.rutka@erlang-solutions.com>
%%% @doc Callback module for OpenFlow Channel application.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofc_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%%%-----------------------------------------------------------------------------
%%% Application callbacks
%%%-----------------------------------------------------------------------------

%% @doc Start the application.
-spec start(any(), any()) -> {ok, pid()}.
start(_StartType, _StartArgs) ->
    ofc_sup:start_link().

%% @doc Stop the application
-spec stop(any()) -> ok.
stop(_State) ->
    ok.
