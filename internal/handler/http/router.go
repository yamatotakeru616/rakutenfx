package http

import (
	"embed"
	"io/fs"
	"net/http"

	"github.com/gin-gonic/gin"
)

// SetupRouter configures all Gin HTTP & WebSocket routes including embedded assets.
func SetupRouter(h *Handler, staticFS embed.FS) *gin.Engine {
	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Recovery())
	r.Use(gin.Logger())

	// CORS & Security headers
	r.Use(func(c *gin.Context) {
		c.Writer.Header().Set("Access-Control-Allow-Origin", "*")
		c.Writer.Header().Set("Access-Control-Allow-Methods", "POST, GET, OPTIONS, PUT, DELETE")
		c.Writer.Header().Set("Access-Control-Allow-Headers", "Content-Type, Content-Length, Accept-Encoding, X-CSRF-Token, Authorization")
		if c.Request.Method == "OPTIONS" {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}
		c.Next()
	})

	// Static assets from go:embed
	staticContent, err := fs.Sub(staticFS, "static")
	if err == nil {
		r.StaticFS("/static", http.FS(staticContent))
		r.GET("/", func(c *gin.Context) {
			indexData, err := fs.ReadFile(staticContent, "index.html")
			if err != nil {
				c.String(http.StatusInternalServerError, "Failed to load embedded dashboard")
				return
			}
			c.Data(http.StatusOK, "text/html; charset=utf-8", indexData)
		})
	}

	// API Routes
	api := r.Group("/api")
	{
		api.GET("/status", h.GetSystemStatus)
		api.GET("/metrics", h.GetMetrics)
		api.GET("/trades", h.GetTrades)
		api.GET("/signals", h.GetSignals)
		api.POST("/ai/evaluate", h.GenerateAiReport)
		api.POST("/kill-switch", h.ToggleKillSwitch)
	}

	// WebSocket endpoint
	r.GET("/ws", h.wsHub.HandleWS)

	return r
}
