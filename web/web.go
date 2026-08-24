package web

import "embed"

// StaticFS holds embedded frontend static assets.
//
//go:embed static/*
var StaticFS embed.FS
