# Sunwhirl – Real-Time Sun & Shadow Visualization App

Sunwhirl is a Flutter-based, cross-platform application that helps users determine whether a location is in sunlight or shadow at a specific time of day. The app combines geospatial data, sun position algorithms, and building footprint analysis to deliver realistic, map-based visualizations of sun direction, moon indicators, and dynamic building shadows.

The project focuses on real-world geospatial problem-solving, performance optimization, and building scalable mobile architectures for map-driven applications.

---

## 🌍 Key Features

- **Real-Time Sun & Moon Positioning**  
  Calculates solar altitude and azimuth based on time, date, and geographic coordinates to determine sun or moon visibility.

- **Dynamic Building Shadow Projection**  
  Uses building outlines and height data from the Overpass API to generate realistic shadow geometry aligned with sun direction and elevation.

- **Map-Based Visualization**  
  Integrates Mapbox maps to render interactive layers for cafés, parks, and public spaces with visual sun/shade indicators.

- **Geospatial Reasoning**  
  Detects whether a selected location falls within a shadow radius using raycasting and proximity-based building analysis.

- **Cross-Platform Architecture**  
  Runs on Android, iOS, Web, Windows, macOS, and Linux using a shared Flutter codebase.

---

## 🧠 System Architecture

The application is designed with a modular, service-oriented structure:

- **UI Layer (Flutter Widgets)**  
  Renders map views, location markers, sun/moon indicators, and filter controls.

- **Geospatial Services**  
  Handles sun position calculations, shadow geometry generation, and spatial reasoning logic.

- **Building Data Service**  
  Fetches and processes building footprints and height metadata from the Overpass API.

- **Map Rendering Layer**  
  Integrates Mapbox SDK to display real-time overlays, polygons, and directional indicators.

This separation allows the system to scale, remain testable, and support future extensions such as offline mode or predictive sunlight modeling.

---

## 🛠️ Tech Stack

- **Frontend / Mobile:** Flutter (Dart)  
- **Maps & Visualization:** Mapbox  
- **Geospatial Data:** Overpass API (OpenStreetMap)  
- **Sun Calculations:** Custom solar position algorithms (azimuth & altitude)  
- **Architecture:** Modular service-based design

---

## 🎯 Use Cases

- Finding sunlit or shaded cafés, parks, and outdoor seating  
- Urban planning and sunlight exposure analysis  
- Outdoor activity planning  
- Geospatial visualization and mapping research

---

## 🚀 Engineering Focus

This project demonstrates:

- Real-time geospatial computation in mobile applications  
- Integration of third-party mapping and open data APIs  
- Performance-aware rendering of dynamic polygons and overlays  
- Clean separation of UI, logic, and service layers for maintainability

---

## 👤 Author

**Tilen Švab**  
Full-Stack & Mobile Developer | Geospatial & AI-Oriented Engineering  
GitHub: https://github.com/krea02

---

## ⚠️ Disclaimer

This project is a demonstration and research-oriented application. Accuracy of shadow projection and sunlight modeling depends on available building metadata and map data quality.
