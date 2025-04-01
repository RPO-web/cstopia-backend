// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

// Define hooks and UI enhancements
const UIManager = {
  // Initialize all UI enhancements
  init() {
    this.loadSortableJS();
    this.setupAlpineJS();
  },

  // Load Sortable.js dynamically
  loadSortableJS() {
    const script = document.createElement('script');
    script.src = 'https://cdn.jsdelivr.net/npm/sortablejs@1.15.0/Sortable.min.js';
    script.onload = () => this.initializeSortables();
    document.head.appendChild(script);
  },

  // Initialize any sortable components on the page
  initializeSortables() {
    document.querySelectorAll('[phx-hook="SortablePlayers"]').forEach(el => {
      const viewName = el.getAttribute('data-phx-view');
      const view = window.liveSocket.getViewByEl(el);
      if (view && view.hooks[viewName]) {
        view.hooks[viewName].initSortable();
      }
    });
  },

  // Setup Alpine.js components when available
  setupAlpineJS() {
    const setupTooltips = () => {
      window.Alpine.data('tooltip', () => ({
        show: false,
        text: '',
        init() {
          this.text = this.$el.dataset.tooltip;
          this.show = false;
        },
        mouseEnter() { this.show = true; },
        mouseLeave() { this.show = false; }
      }));
    };

    if (typeof window.Alpine === 'undefined') {
      document.addEventListener('alpine:init', setupTooltips);
    } else {
      setupTooltips();
    }
  }
};

// LiveView hooks
let Hooks = {
  // Sortable players list hook
  SortablePlayers: {
    mounted() {
      if (typeof window.Sortable === 'undefined') return;
      this.initSortable();
    },
    
    initSortable() {
      if (!this.el || !window.Sortable) return;
      
      const leaderId = this.el.dataset.leaderId;
      const currentUserId = document.querySelector("meta[name='user-id']")?.getAttribute("content");
      
      if (currentUserId === leaderId) {
        this.sortable = new window.Sortable(this.el, {
          animation: 150,
          handle: '.drag-handle',
          ghostClass: 'bg-indigo-100',
          onEnd: (evt) => {
            const positions = {};
            Array.from(this.el.children).forEach((item, index) => {
              // Add 1 to account for leader at position 0
              positions[item.dataset.id] = index + 1;
            });
            
            this.pushEvent("update-player-positions", { positions });
          }
        });
      }
    },
    
    updated() {
      // No need to manually reorder since host is separate
    },
    
    destroyed() {
      if (this.sortable) this.sortable.destroy();
    }
  }
};

// Initialize LiveView
const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
});

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"});
window.addEventListener("phx:page-loading-start", _info => topbar.show(300));
window.addEventListener("phx:page-loading-stop", _info => topbar.hide());

// Connect if there are any LiveViews on the page
liveSocket.connect();

// Expose liveSocket on window for web console debug logs
window.liveSocket = liveSocket;

// Initialize UI enhancements when DOM is ready
document.addEventListener('DOMContentLoaded', () => UIManager.init());

