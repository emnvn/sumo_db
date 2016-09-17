PROJECT = sumo_db

CONFIG ?= test/test.config

DEPS = lager worker_pool riakc uuid

dep_lager = git https://github.com/basho/lager.git 3.0.0
dep_worker_pool = git https://github.com/inaka/worker_pool.git 2.2.0
dep_riakc = git https://github.com/inaka/riak-erlang-client.git 2.1.1-R18
dep_uuid = git git://github.com/okeuday/uuid.git v1.5.3

TEST_DEPS = mixer
dep_mixer = git git://github.com/inaka/mixer.git 0.1.3

PLT_APPS := mnesia
DIALYZER_DIRS := ebin/
DIALYZER_OPTS := --verbose --statistics -Werror_handling \
                 -Wrace_conditions #-Wunmatched_returns

include erlang.mk

ERLC_OPTS += +'{parse_transform, lager_transform}'
ERLC_OPTS += +warn_unused_vars +warn_export_all +warn_shadow_vars +warn_unused_import +warn_unused_function
ERLC_OPTS += +warn_bif_clash +warn_unused_record +warn_deprecated_function +warn_obsolete_guard +strict_validation
ERLC_OPTS += +warn_export_vars +warn_exported_vars +warn_missing_spec +warn_untyped_record +debug_info

COMPILE_FIRST += sumo_backend sumo_doc sumo_store
# Commont Test Config

TEST_ERLC_OPTS += +'{parse_transform, lager_transform}'
CT_OPTS = -cover test/sumo.coverspec -vvv -erl_args -config ${CONFIG}

SHELL_OPTS = -name ${PROJECT}@`hostname` -config ${CONFIG} -s sync

test-shell: build-ct-suites app
	erl -pa ebin -pa deps/*/ebin -pa test -s lager -s sync -config ${CONFIG}

erldocs:
	erldocs . -o docs

changelog:
	github_changelog_generator --token ${TOKEN}

quicktests: app build-ct-suites
	@if [ -d "test" ] ; \
	then \
		mkdir -p logs/ ; \
		$(CT_RUN) -suite $(addsuffix _SUITE,$(CT_SUITES)) $(CT_OPTS) ; \
	fi
	$(gen_verbose) rm -f test/*.beam
