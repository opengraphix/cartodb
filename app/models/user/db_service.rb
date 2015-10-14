
require_relative 'db_queries'

# To avoid collisions with User model
module CartoDB
  module User
    class DBService

      # Also default schema for new users
      SCHEMA_PUBLIC = 'public'
      SCHEMA_CARTODB = 'cartodb'
      SCHEMA_IMPORTER = 'cdb_importer'

      def initialize(user)
        raise "User nil" unless user
        @user = user
        @queries = CartoDB::User::DBQueries.new(@user)
      end

      def queries
        @queries
      end

      def configure_database
        grant_user_in_database
        set_user_privileges_at_db
        set_statement_timeouts
        setup_schema if @user.database_schema != SCHEMA_PUBLIC
        create_function_invalidate_varnish

        @user.reload
      end

      # INFO: This method is used both when creating a new user and by the relocator
      # when user is relocated to an org database.
      def setup_schema
        reset_user_schema_permissions
        reset_schema_owner
        set_user_privileges_at_db
        set_user_as_organization_member
        rebuild_quota_trigger

        # INFO: organization privileges are set for org_member_role, which is assigned to each org user
        if @user.organization_owner?
          setup_organization_owner
        end
      end

      def rebuild_quota_trigger
        puts "Setting user quota in db '#{@user.database_name}' (#{@user.username})"
        @user.in_database(as: :superuser) do |db|
          if !@user.cartodb_extension_version_pre_mu? && @user.has_organization?
            db.run("DROP FUNCTION IF EXISTS public._CDB_UserQuotaInBytes();")
          end

          db.transaction do
            # NOTE: this has been written to work for both databases that switched to "cartodb" extension
            #       and those before the switch.
            #       In the future we should guarantee that exntension lives in cartodb schema so we don't need to set
            #       a search_path before
            search_path = db.fetch("SHOW search_path;").first[:search_path]
            db.run("SET search_path TO cartodb, public;")
            if @user.cartodb_extension_version_pre_mu?
              db.run("SELECT CDB_SetUserQuotaInBytes(#{@user.quota_in_bytes});")
            else
              db.run("SELECT CDB_SetUserQuotaInBytes('#{@user.database_schema}', #{@user.quota_in_bytes});")
            end
            db.run("SET search_path TO #{search_path};")
          end
        end
      end

      def setup_owner_permissions
        @user.in_database(as: :superuser) do |database|
          database.run(%{ SELECT cartodb.CDB_Organization_AddAdmin('#{@user.username}') })
        end
      end

      def configure_extension_org_metadata_api_endpoint
        config = Cartodb.config[:org_metadata_api]
        host = config['host']
        port = config['port']
        username = config['username']
        password = config['password']
        timeout = config.fetch('timeout', 10)

        if host.present? && port.present? && username.present? && password.present?
          conf_sql = %{
            SELECT cartodb.CDB_Conf_SetConf('groups_api',
              '{ \"host\": \"#{host}\", \"port\": #{port}, \"timeout\": #{timeout}, \"username\": \"#{username}\", \"password\": \"#{password}\"}'::json
            )
          }
          @user.in_database(as: :superuser) do |database|
            database.fetch(conf_sql).first
          end
        else
          CartoDB.notify_debug("org_metadata_api configuration missing", user_id: @user.id, config: config)
        end
      end

      def setup_organization_owner
        setup_organization_role_permissions
        setup_owner_permissions
        configure_extension_org_metadata_api_endpoint
      end

      def reset_user_schema_permissions
        @user.in_database(as: :superuser) do |user_database|
          user_database.transaction do
            schemas = [@user.database_schema].uniq
            schemas.each do |schema|
              revoke_privileges(user_database, schema, 'PUBLIC')
            end
            yield(user_database) if block_given?
          end
        end
      end

      def reset_database_permissions
        @user.in_database(as: :superuser) do |user_database|
          user_database.transaction do
            schemas = %w(public cdb_importer cdb cartodb)
            ['PUBLIC', CartoDB::PUBLIC_DB_USER].each do |user|
              revoke_all_on_database_from(user_database, @user.database_name, user)
              schemas.each do |schema|
                revoke_privileges(user_database, schema, user)
              end
            end
            yield(user_database) if block_given?
          end
        end
      end

      def set_statement_timeouts
        @user.in_database(as: :superuser) do |user_database|
          user_database["ALTER ROLE \"?\" SET statement_timeout to ?", @user.database_username.lit,
                        @user.user_timeout].all
          user_database["ALTER DATABASE \"?\" SET statement_timeout to ?", @user.database_name.lit,
                        @user.database_timeout].all
        end
        @user.in_database.disconnect
        @user.in_database.connect(db_configuration_for)
        @user.in_database(as: :public_user).disconnect
        @user.in_database(as: :public_user).connect(db_configuration_for(:public_user))
      rescue Sequel::DatabaseConnectionError
      end

      def set_user_privileges_at_db # MU
        # INFO: organization permission on public schema is handled through role assignment
        unless @user.organization_user?
          set_user_privileges_in_cartodb_schema
          set_user_privileges_in_public_schema
        end

        set_user_privileges_in_own_schema
        set_privileges_to_publicuser_in_own_schema

        unless @user.organization_user?
          set_user_privileges_in_importer_schema
          set_user_privileges_in_geocoding_schema
          set_geo_columns_privileges
          set_raster_privileges
        end
      end

      def set_user_as_organization_member
        @user.in_database(as: :superuser) do |user_database|
          user_database.transaction do
            user_database.run("SELECT cartodb.CDB_Organization_Create_Member('#{@user.database_username}');")
          end
        end
      end

      def reset_schema_owner
        @user.in_database(as: :superuser) do |database|
          database.run(%{ALTER SCHEMA "#{@user.database_schema}" OWNER TO "#{@user.database_username}"})
        end
      end

      def grant_user_in_database
        @queries.run_in_transaction(
          @queries.grant_connect_on_database_queries,
          true
        )
      end

      def grant_publicuser_in_database
        @queries.run_in_transaction(
          @queries.grant_connect_on_database_queries(CartoDB::PUBLIC_DB_USER),
          true
        )
        @queries.run_in_transaction(
          @queries.grant_read_on_schema_queries(SCHEMA_CARTODB, CartoDB::PUBLIC_DB_USER),
          true
        )
        @queries.run_in_transaction(
          [
            "REVOKE SELECT ON cartodb.cdb_tablemetadata FROM #{CartoDB::PUBLIC_DB_USER} CASCADE"
          ],
          true
        )
        @queries.run_in_transaction(
          [
            "GRANT USAGE ON SCHEMA #{SCHEMA_PUBLIC} TO #{CartoDB::PUBLIC_DB_USER}",
            "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA #{SCHEMA_PUBLIC} TO #{CartoDB::PUBLIC_DB_USER}",
            "GRANT SELECT ON spatial_ref_sys TO #{CartoDB::PUBLIC_DB_USER}"
          ],
          true
        )
      end

      def set_user_privileges_in_own_schema # MU
        @queries.run_in_transaction(
          @queries.grant_all_on_user_schema_queries,
          true
        )
      end

      def set_user_privileges_in_cartodb_schema(db_user = nil)
        @queries.run_in_transaction(
          (
            @queries.grant_read_on_schema_queries(SCHEMA_CARTODB, db_user) +
            @queries.grant_write_on_cdb_tablemetadata_queries(db_user)
          ),
          true
        )
      end

      def set_privileges_to_publicuser_in_own_schema # MU
        # Privileges in user schema for publicuser
        @queries.run_in_transaction(
          @queries.grant_usage_on_user_schema_to_other(CartoDB::PUBLIC_DB_USER),
          true
        )
      end

      def set_user_privileges_in_public_schema(db_user = nil)
        @queries.run_in_transaction(
          @queries.grant_read_on_schema_queries(SCHEMA_PUBLIC, db_user),
          true
        )
      end

      def set_user_privileges_in_importer_schema(db_user = nil) # MU
        @queries.run_in_transaction(
          @queries.grant_all_on_schema_queries(SCHEMA_IMPORTER, db_user),
          true
        )
      end

      def revoke_all_on_database_from(conn, database, role)
        conn.run("REVOKE ALL ON DATABASE \"#{database}\" FROM \"#{role}\" CASCADE") if role_exists?(conn, role)
      end

      def grant_owner_in_database
        @queries.run_in_transaction(
          @queries.grant_all_on_database_queries,
          true
        )
      end

      def fix_table_permissions
        tables_queries = []
        @user.tables.each do |table|
          if table.public? || table.public_with_link_only?
            tables_queries << "GRANT SELECT ON \"#{@user.database_schema}\".\"#{table.name}\" TO #{CartoDB::PUBLIC_DB_USER}"
          end
          tables_queries << "ALTER TABLE \"#{@user.database_schema}\".\"#{table.name}\" OWNER TO \"#{@user.database_username}\""
        end
        @queries.run_in_transaction(
          tables_queries,
          true
        )
      end

      def set_user_privileges_in_geocoding_schema(db_user = nil)
        @queries.run_in_transaction(
          @queries.grant_all_on_schema_queries('cdb', db_user),
          true
        )
      end

      def set_geo_columns_privileges(role_name = nil)
        # Postgis lives at public schema, as do geometry_columns and geography_columns
        catalogs_schema = SCHEMA_PUBLIC
        target_user = role_name.nil? ? @user.database_public_username : role_name
        queries = [
          %{ GRANT SELECT ON "#{catalogs_schema}"."geometry_columns" TO "#{target_user}" },
          %{ GRANT SELECT ON "#{catalogs_schema}"."geography_columns" TO "#{target_user}" }
        ]
        @queries.run_in_transaction(queries, true)
      end

      def set_raster_privileges(role_name = nil)
        # Postgis lives at public schema, so raster catalogs too
        catalogs_schema = SCHEMA_PUBLIC
        queries = [
          "GRANT SELECT ON TABLE \"#{catalogs_schema}\".\"raster_overviews\" TO \"#{CartoDB::PUBLIC_DB_USER}\"",
          "GRANT SELECT ON TABLE \"#{catalogs_schema}\".\"raster_columns\" TO \"#{CartoDB::PUBLIC_DB_USER}\""
        ]
        target_user = role_name.nil? ? @user.database_public_username : role_name
        unless @user.organization.nil?
          queries << "GRANT SELECT ON TABLE \"#{catalogs_schema}\".\"raster_overviews\" TO \"#{target_user}\""
          queries << "GRANT SELECT ON TABLE \"#{catalogs_schema}\".\"raster_columns\" TO \"#{target_user}\""
        end
        @queries.run_in_transaction(queries, true)
      end

      def setup_organization_role_permissions
        org_member_role = organization_member_group_role_member_name
        set_user_privileges_in_public_schema(org_member_role)
        @queries.run_in_transaction(
          @queries.grant_connect_on_database_queries(org_member_role), true
        )
        set_geo_columns_privileges(org_member_role)
        set_raster_privileges(org_member_role)
        set_user_privileges_in_cartodb_schema(org_member_role)
        set_user_privileges_in_importer_schema(org_member_role)
        set_user_privileges_in_geocoding_schema(org_member_role)
      end


      def drop_users_privileges_in_schema(schema, accounts)
        @user.in_database(as: :superuser, statement_timeout: 600000) do |user_database|
          if user_database.fetch(
            "SELECT 1 as schema_exist FROM information_schema.schemata WHERE schema_name = '#{schema}'"
          ).first.nil?
            return
          end
          user_database.transaction do
            accounts
              .select { |role| role_exists?(user_database, role) }
              .each { |role| revoke_privileges(user_database, schema, "\"#{role}\"") }
          end
        end
      end

      def revoke_all_memberships_on_database_to_role(conn, role)
        conn.fetch(%{
            select rolname from pg_user join pg_auth_members on (pg_user.usesysid=pg_auth_members.member)
            join pg_roles on (pg_roles.oid=pg_auth_members.roleid) where pg_user.usename='#{role}'
          }).each do |rolname|
          conn.run("REVOKE \"#{rolname[:rolname]}\" FROM \"#{role}\" CASCADE")
        end
      end

      # Drops grants and functions in a given schema, avoiding by all means a CASCADE
      # to not affect extensions or other users
      def drop_all_functions_from_schema(schema_name)
        recursivity_max_depth = 3

        return if schema_name == SCHEMA_PUBLIC

        @user.in_database(as: :superuser) do |database|
          # Non-aggregate functions
          drop_function_sqls = database.fetch(%{
            SELECT 'DROP FUNCTION ' || ns.nspname || '.' || proname || '(' || oidvectortypes(proargtypes) || ');'
              AS sql
            FROM pg_proc INNER JOIN pg_namespace ns ON (pg_proc.pronamespace = ns.oid AND pg_proc.proisagg = FALSE)
            WHERE ns.nspname = '#{schema_name}'
          })

          # Simulate a controlled environment drop cascade contained to only functions
          failed_sqls = []
          recursivity_level = 0
          begin
            failed_sqls = []
            drop_function_sqls.each do |sql_sentence|
              begin
                database.run(sql_sentence[:sql])
              rescue Sequel::DatabaseError => e
                if e.message =~ /depends on function /i
                  failed_sqls.push(sql_sentence)
                else
                  raise
                end
              end
            end
            drop_function_sqls = failed_sqls
            recursivity_level += 1
          end while failed_sqls.count > 0 && recursivity_level < recursivity_max_depth

          # If something remains, reattempt later after dropping aggregates
          if drop_function_sqls.count > 0
            aggregate_dependant_function_sqls = drop_function_sqls
          else
            aggregate_dependant_function_sqls = []
          end

          # And now aggregate functions
          failed_sqls = []
          drop_function_sqls = database.fetch(%{
            SELECT 'DROP AGGREGATE ' || ns.nspname || '.' || proname || '(' || oidvectortypes(proargtypes) || ');'
              AS sql
            FROM pg_proc INNER JOIN pg_namespace ns ON (pg_proc.pronamespace = ns.oid AND pg_proc.proisagg = TRUE)
            WHERE ns.nspname = '#{schema_name}'
          })
          drop_function_sqls.each do |sql_sentence|
            begin
              database.run(sql_sentence[:sql])
            rescue Sequel::DatabaseError
              failed_sqls.push(sql_sentence)
            end
          end

          if failed_sqls.count > 0
            raise CartoDB::BaseCartoDBError.new('Cannot drop schema aggregate functions, dependencies remain')
          end

          # One final pass of normal functions, if left
          if aggregate_dependant_function_sqls.count > 0
            aggregate_dependant_function_sqls.each do |sql_sentence|
              begin
                database.run(sql_sentence[:sql])
              rescue Sequel::DatabaseError
                failed_sqls.push(sql_sentence)
              end
            end
          end

          if failed_sqls.count > 0
            raise CartoDB::BaseCartoDBError.new('Cannot drop schema functions, dependencies remain')
          end
        end
      end

      # Create a "public.cdb_invalidate_varnish()" function to invalidate Varnish
      #
      # The function can only be used by the superuser, we expect
      # security-definer triggers OR triggers on superuser-owned tables
      # to call it with controlled set of parameters.
      #
      # The function is written in python because it needs to reach out
      # to a Varnish server.
      #
      # Being unable to communicate with Varnish may or may not be critical
      # depending on CartoDB configuration at time of function definition.
      #
      def create_function_invalidate_varnish
        if Cartodb.config[:invalidation_service] && Cartodb.config[:invalidation_service].fetch('enabled', false)
          create_function_invalidate_varnish_invalidation_service
        elsif Cartodb.config[:varnish_management].fetch('http_port', false)
          create_function_invalidate_varnish_http
        else
          create_function_invalidate_varnish_telnet
        end
      end

      # Add plpythonu pl handler
      def add_python
        @user.in_database(
          as: :superuser,
          no_cartodb_in_schema: true
        ).run("CREATE OR REPLACE PROCEDURAL LANGUAGE 'plpythonu' HANDLER plpython_call_handler;")
      end

      # Needed because in some cases it might not exist and failure ends transaction
      def role_exists?(db, role)
        !db.fetch("SELECT 1 FROM pg_roles WHERE rolname='#{role}'").first.nil?
      end

      def revoke_privileges(db, schema, user)
        db.run("REVOKE ALL ON SCHEMA \"#{schema}\" FROM #{user} CASCADE")
        db.run("REVOKE ALL ON ALL SEQUENCES IN SCHEMA \"#{schema}\" FROM #{user} CASCADE")
        db.run("REVOKE ALL ON ALL FUNCTIONS IN SCHEMA \"#{schema}\" FROM #{user} CASCADE")
        db.run("REVOKE ALL ON ALL TABLES IN SCHEMA \"#{schema}\" FROM #{user} CASCADE")
      end

      def organization_member_group_role_member_name
        @user.in_database.fetch(
          "SELECT cartodb.CDB_Organization_Member_Group_Role_Member_Name() as org_member_role;"
        )[:org_member_role][:org_member_role]
      end

      def db_configuration_for(user_role = nil)
        logger = (Rails.env.development? || Rails.env.test? ? ::Rails.logger : nil)
        if user_role == :superuser
          ::Rails::Sequel.configuration.environment_for(Rails.env).merge(
            'database' => @user.database_name,
            :logger => logger,
            'host' => @user.database_host
          ) { |_, o, n| n.nil? ? o : n }
        elsif user_role == :cluster_admin
          ::Rails::Sequel.configuration.environment_for(Rails.env).merge(
            'database' => 'postgres',
            :logger => logger,
            'host' => @user.database_host
          ) { |_, o, n| n.nil? ? o : n }
        elsif user_role == :public_user
          ::Rails::Sequel.configuration.environment_for(Rails.env).merge(
            'database' => @user.database_name,
            :logger => logger,
            'username' => CartoDB::PUBLIC_DB_USER, 'password' => CartoDB::PUBLIC_DB_USER_PASSWORD,
            'host' => @user.database_host
          ) { |_, o, n| n.nil? ? o : n }
        elsif user_role == :public_db_user
          ::Rails::Sequel.configuration.environment_for(Rails.env).merge(
            'database' => @user.database_name,
            :logger => logger,
            'username' => @user.database_public_username, 'password' => CartoDB::PUBLIC_DB_USER_PASSWORD,
            'host' => @user.database_host
          ) { |_, o, n| n.nil? ? o : n }
        else
          ::Rails::Sequel.configuration.environment_for(Rails.env).merge(
            'database' => @user.database_name,
            :logger => logger,
            'username' => @user.database_username,
            'password' => @user.database_password,
            'host' => @user.database_host
          ) { |_, o, n| n.nil? ? o : n }
        end
      end

      private

      # Telnet invalidation works only for Varnish 2.x.
      def create_function_invalidate_varnish_telnet
        add_python

        varnish_host = Cartodb.config[:varnish_management].try(:[], 'host') || '127.0.0.1'
        varnish_port = Cartodb.config[:varnish_management].try(:[], 'port') || 6082
        varnish_timeout = Cartodb.config[:varnish_management].try(:[], 'timeout') || 5
        varnish_critical = Cartodb.config[:varnish_management].try(:[], 'critical') == true ? 1 : 0
        varnish_retry = Cartodb.config[:varnish_management].try(:[], 'retry') || 5
        purge_command = Cartodb::config[:varnish_management]["purge_command"]
        varnish_trigger_verbose = Cartodb.config[:varnish_management].fetch('trigger_verbose', true) == true ? 1 : 0

        @user.in_database(as: :superuser).run(
          <<-TRIGGER
            BEGIN;
            CREATE OR REPLACE FUNCTION public.cdb_invalidate_varnish(table_name text) RETURNS void AS
            $$
                critical = #{varnish_critical}
                timeout = #{varnish_timeout}
                retry = #{varnish_retry}
                trigger_verbose = #{varnish_trigger_verbose}

                client = GD.get('varnish', None)

                while True:

                  if not client:
                      try:
                        import varnish
                        client = GD['varnish'] = varnish.VarnishHandler(('#{varnish_host}', #{varnish_port}, timeout))
                      except Exception as err:
                        # NOTE: we won't retry on connection error
                        if critical:
                          plpy.error('Varnish connection error: ' +  str(err))
                        break

                  try:
                    # NOTE: every table change also changed CDB_TableMetadata, so
                    #       we purge those entries too
                    #
                    # TODO: do not invalidate responses with surrogate key
                    #       "not_this_one" when table "this" changes :/
                    #       --strk-20131203;
                    #
                    client.fetch('#{purge_command} obj.http.X-Cache-Channel ~ "^#{@user.database_name}:(.*%s.*)|(cdb_tablemetadata)|(table)$"' % table_name.replace('"',''))
                    break
                  except Exception as err:
                    if trigger_verbose:
                      plpy.warning('Varnish fetch error: ' + str(err))
                    client = GD['varnish'] = None # force reconnect
                    if not retry:
                      if critical:
                        plpy.error('Varnish fetch error: ' +  str(err))
                      break
                    retry -= 1 # try reconnecting
            $$
            LANGUAGE 'plpythonu' VOLATILE;
            REVOKE ALL ON FUNCTION public.cdb_invalidate_varnish(TEXT) FROM PUBLIC;
            COMMIT;
        TRIGGER
        )
      end

      def create_function_invalidate_varnish_http
        add_python

        varnish_host = Cartodb.config[:varnish_management].try(:[], 'host') || '127.0.0.1'
        varnish_port = Cartodb.config[:varnish_management].try(:[], 'http_port') || 6081
        varnish_timeout = Cartodb.config[:varnish_management].try(:[], 'timeout') || 5
        varnish_critical = Cartodb.config[:varnish_management].try(:[], 'critical') == true ? 1 : 0
        varnish_retry = Cartodb.config[:varnish_management].try(:[], 'retry') || 5
        varnish_trigger_verbose = Cartodb.config[:varnish_management].fetch('trigger_verbose', true) == true ? 1 : 0

        @user.in_database(as: :superuser).run(
          <<-TRIGGER
            BEGIN;
            CREATE OR REPLACE FUNCTION public.cdb_invalidate_varnish(table_name text) RETURNS void AS
            $$
                critical = #{varnish_critical}
                timeout = #{varnish_timeout}
                retry = #{varnish_retry}
                trigger_verbose = #{varnish_trigger_verbose}

                import httplib

                while True:

                  try:
                    # NOTE: every table change also changed CDB_TableMetadata, so
                    #       we purge those entries too
                    #
                    # TODO: do not invalidate responses with surrogate key
                    #       "not_this_one" when table "this" changes :/
                    #       --strk-20131203;
                    #
                    client = httplib.HTTPConnection('#{varnish_host}', #{varnish_port}, False, timeout)
                    client.request('PURGE', '/batch', '', {"Invalidation-Match": ('^#{@user.database_name}:(.*%s.*)|(cdb_tablemetadata)|(table)$' % table_name.replace('"',''))  })
                    response = client.getresponse()
                    assert response.status == 204
                    break
                  except Exception as err:
                    if trigger_verbose:
                      plpy.warning('Varnish purge error: ' + str(err))
                    if not retry:
                      if critical:
                        plpy.error('Varnish purge error: ' +  str(err))
                      break
                    retry -= 1 # try reconnecting
            $$
            LANGUAGE 'plpythonu' VOLATILE;
            REVOKE ALL ON FUNCTION public.cdb_invalidate_varnish(TEXT) FROM PUBLIC;
            COMMIT;
          TRIGGER
        )
      end

      # Invalidate through external service
      def create_function_invalidate_varnish_invalidation_service
        add_python

        invalidation_host = Cartodb.config[:invalidation_service].try(:[], 'host') || '127.0.0.1'
        invalidation_port = Cartodb.config[:invalidation_service].try(:[], 'port') || 3142
        invalidation_timeout = Cartodb.config[:invalidation_service].try(:[], 'timeout') || 5
        invalidation_critical = Cartodb.config[:invalidation_service].try(:[], 'critical') ? 1 : 0
        invalidation_retry = Cartodb.config[:invalidation_service].try(:[], 'retry') || 5
        invalidation_trigger_verbose =
          Cartodb.config[:invalidation_service].fetch('trigger_verbose', true) == true ? 1 : 0

        @user.in_database(as: :superuser).run(
          <<-TRIGGER
            BEGIN;
            CREATE OR REPLACE FUNCTION public.cdb_invalidate_varnish(table_name text) RETURNS void AS
            $$
                critical = #{invalidation_critical}
                timeout = #{invalidation_timeout}
                retry = #{invalidation_retry}
                trigger_verbose = #{invalidation_trigger_verbose}

                client = GD.get('invalidation', None)

                while True:

                  if not client:
                      try:
                        import redis
                        client = GD['invalidation'] = redis.Redis(host='#{invalidation_host}', port=#{invalidation_port}, socket_timeout=timeout)
                      except Exception as err:
                        # NOTE: we won't retry on connection error
                        if critical:
                          plpy.error('Invalidation Service connection error: ' +  str(err))
                        break

                  try:
                    client.execute_command('TCH', '#{@user.database_name}', table_name)
                    break
                  except Exception as err:
                    if trigger_verbose:
                      plpy.warning('Invalidation Service warning: ' + str(err))
                    client = GD['invalidation'] = None # force reconnect
                    if not retry:
                      if critical:
                        plpy.error('Invalidation Service error: ' +  str(err))
                      break
                    retry -= 1 # try reconnecting
            $$
            LANGUAGE 'plpythonu' VOLATILE;
            REVOKE ALL ON FUNCTION public.cdb_invalidate_varnish(TEXT) FROM PUBLIC;
            COMMIT;
          TRIGGER
        )
      end

    end
  end
end