// Command api runs the DAYMARK REST API. `api migrate` applies migrations and exits.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/daymark/daymark/backend/internal/api"
	"github.com/daymark/daymark/backend/internal/config"
	"github.com/daymark/daymark/backend/internal/database"
	"github.com/daymark/daymark/backend/migrations"
)

var version = "dev" // set with -ldflags "-X main.version=..."

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg, err := config.FromOS()
	if err != nil {
		log.Error("invalid configuration", "err", err.Error())
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	db, err := database.Open(ctx, cfg.DatabaseURL, cfg.DBMaxOpenConns)
	if err != nil {
		log.Error("database", "err", err.Error())
		os.Exit(1)
	}
	defer db.Close()

	migrateOnly := len(os.Args) > 1 && os.Args[1] == "migrate"
	if cfg.MigrateOnStart || migrateOnly {
		applied, err := database.Migrate(ctx, db, migrations.FS)
		if err != nil {
			log.Error("migration failed", "err", err.Error())
			os.Exit(1)
		}
		log.Info("migrations complete", "applied", applied)
		if migrateOnly {
			return
		}
	}

	srv := api.New(cfg, db, log, version)
	go srv.RunMaintenance(ctx)

	httpSrv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       60 * time.Second,
		WriteTimeout:      150 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}
	go func() {
		<-ctx.Done()
		log.Info("shutting down")
		sctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		if err := httpSrv.Shutdown(sctx); err != nil {
			log.Error("shutdown", "err", err.Error())
		}
	}()
	log.Info("listening", "addr", cfg.Addr, "env", cfg.Env, "version", version)
	if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Error("server", "err", err.Error())
		os.Exit(1)
	}
}
