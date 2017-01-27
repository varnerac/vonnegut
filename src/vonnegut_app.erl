%%%-------------------------------------------------------------------
%% @doc vonnegut public API
%% @end
%%%-------------------------------------------------------------------

-module(vonnegut_app).

-behaviour(application).

%% Application callbacks
-export([start/2
        ,stop/1]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    vg_log_segments:init_table(),
    vonnegut_sup:start_link().

%%--------------------------------------------------------------------
stop(_State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================
