# Change data directory

- Find the location of configuration file and data directory
    
    ```bash
    postgres@node-db-01:~$ psql -U postgres 
    Password for user postgres: 
    psql (16.11 (Ubuntu 16.11-1.pgdg22.04+1))
    Type "help" for help.
    
    postgres=# show config_file;
                   config_file               
    -----------------------------------------
     /etc/postgresql/16/main/postgresql.conf
    (1 row)
    
    postgres=# show data_directory;
           data_directory        
    -----------------------------
     /var/lib/postgresql/16/main
    (1 row)
    ```
    
- Stop postgresql service
    
    ```bash
    sudo systemctl stop postgresql@16-main.service 
    ```
    
- Move data to the new location
    - Create a directory, ensure it have enough space available
    - Grant the postgres user ownership and permissions
    - Copy data directory to the new location
        
        ```bash
        new_pg_data_dir="/u01/data/postgresql/16"
        mkdir -p $new_pg_data_dir
        chown postgres:postgres $new_pg_data_dir
        rsync -av /var/lib/postgresql/16/main $new_pg_data_dir
        ```
        
- Update postgresql configuration
    - Open configuration file at  `/etc/postgresql/16/main/postgresql.conf`
    - Update data_directory to the new location
        
        ```bash
        #------------------------------------------------------------------------------
        # FILE LOCATIONS
        #------------------------------------------------------------------------------
        
        # The default values of these variables are driven from the -D command-line
        # option or PGDATA environment variable, represented here as ConfigDir.
        
        data_directory = '/u01/data/postgresql/16/main' # use data in another directory
                                                        # (change requires restart)
        
        ```
        
- Start postgresql service
    
    ```bash
    sudo systemctl start postgresql@16-main.service 
    ```
    
- Confirmation
    
    ```bash
    postgres@node-db-01:~$ psql -U postgres 
    Password for user postgres: 
    psql (16.11 (Ubuntu 16.11-1.pgdg22.04+1))
    Type "help" for help.
    
    postgres=# show config_file;
                   config_file               
    -----------------------------------------
     /etc/postgresql/16/main/postgresql.conf
    (1 row)
    
    postgres=# show data_directory;
            data_directory        
    ------------------------------
     /u01/data/postgresql/16/main
    (1 row)
    ```
    

References

- https://fitodic.github.io/how-to-change-postgresql-data-directory-on-linux
- https://www.digitalocean.com/community/tutorials/how-to-move-a-postgresql-data-directory-to-a-new-location-on-ubuntu-16-04