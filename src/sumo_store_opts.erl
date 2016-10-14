-module(sumo_store_opts).

%% Options of mod_cluster. Uses internal compilation for more fast access.

%% API
-export([
	init/1, get_key/1, get_all/0
]).


-define(TEMP_MODULE, sumo_store_opts_data).

init(Opts) ->
	term_compiler:compile(?TEMP_MODULE, [
		{ get, { list, Opts }},
		{ get_all, {term, Opts}}
	]).

get_key(Key) ->
	?TEMP_MODULE:get(Key).

get_all() ->
	?TEMP_MODULE:get_all().



