// Package seed initializes the database with default data at startup.
// It creates a "default" group if none exist and assigns every app that has no groups to it.
// Run is called once from main after opening the store; there is no HTTP API for groups.
package seed

import (
	"log"

	"piaflow/internal/config"
	"piaflow/internal/store"
)

// Run ensures a default group exists and assigns apps without groups to it.
// Idempotent: safe to call on every startup; only creates missing data.
func Run(st *store.Store, apps []config.App) {
	groups, err := st.ListGroups()
	if err != nil {
		log.Printf("seed: list groups: %v", err)
		return
	}
	var defaultGroupID int64
	if len(groups) == 0 {
		defaultGroupID, err = st.CreateGroup("default")
		if err != nil {
			log.Printf("seed: create default group: %v", err)
			return
		}
		log.Printf("seed: created group 'default' (id=%d)", defaultGroupID)
	} else {
		for _, g := range groups {
			if g.Name == "default" {
				defaultGroupID = g.ID
				break
			}
		}
		if defaultGroupID == 0 {
			defaultGroupID = groups[0].ID
		}
	}

	for _, app := range apps {
		ids, _ := st.AppGroupIDs(app.ID)
		if len(ids) == 0 {
			_ = st.SetAppGroups(app.ID, []int64{defaultGroupID})
		}
	}
}
