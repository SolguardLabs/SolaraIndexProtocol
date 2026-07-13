# Política de seguridad

Solara Index Protocol mantiene una política de seguridad orientada a proteger la
custodia de componentes ERC-20, la emisión y redención de `SINDEX`, la integridad
del NAV y la correcta ejecución de rebalanceos. Este documento describe el
alcance de revisión, el modelo de amenazas, las expectativas de reporte y los
controles mínimos para evaluar cambios en el protocolo.

## Alcance

La revisión de seguridad debe centrarse en los contratos, pruebas y scripts de
este repositorio:

- `src/SolaraIndexProtocol.sol`: flujo principal de mint, redeem, rebalance y
  salidas de emergencia.
- `src/token/SolaraIndexToken.sol`: token `SINDEX` emitido por la bóveda.
- `src/core/ComponentRegistry.sol`: registro de componentes, pesos y límites.
- `src/oracle/SolaraPriceOracle.sol`: precios administrados, heartbeat y rangos.
- `src/modules/`: planificación de rebalance y cotización de salidas de
  emergencia.
- `src/lens/`: vistas agregadas de NAV, pesos, claims y cuentas.
- `src/risk/SolaraCircuitBreaker.sol`: guard opcional sobre movimientos de NAV y
  PPS.
- `test/` y `script/`: cobertura Foundry y despliegue local reproducible.

Quedan fuera de alcance las integraciones externas, frontends, infraestructura
operativa, claves privadas, servicios de RPC y despliegues que modifiquen el
código o la configuración publicada en este repositorio.

## Modelo de amenazas

El modelo de análisis asume usuarios públicos capaces de:

- mintear `SINDEX` depositando la cesta requerida de componentes;
- redimir participaciones por activos subyacentes;
- interactuar durante ventanas de rebalance;
- observar precios, pesos, snapshots y datos agregados expuestos por las lens;
- ejecutar secuencias atómicas o multi-transacción dentro de las rutas públicas
  del protocolo.

Las siguientes entidades se consideran privilegiadas:

- administradores de componentes, pesos y límites;
- operadores autorizados del oráculo;
- cuentas con permisos de pausa, configuración o emergencia;
- operadores de despliegue y mantenimiento.

Los hallazgos deben distinguir claramente entre rutas alcanzables por usuarios
públicos, rutas dependientes de permisos administrativos y condiciones que
requieren configuración externa específica.

## Reporte responsable

Para comunicar una debilidad de seguridad o un comportamiento de riesgo:

1. No publiques detalles técnicos completos en un issue público si permiten
   abuso directo.
2. Usa GitHub Private Vulnerability Reporting si está disponible.
3. Si no existe canal privado habilitado, abre un issue público con una
   descripción mínima del área afectada y solicita un canal privado para los
   detalles técnicos.
4. Incluye versión o commit revisado, pasos de reproducción, impacto económico,
   precondiciones, permisos necesarios y una recomendación de mitigación.

No incluyas claves privadas, seeds, endpoints sensibles, credenciales ni datos de
terceros en ningún reporte.

## Severidad

La severidad debe evaluarse por impacto y alcanzabilidad:

- Crítica: pérdida directa de fondos, mint no respaldado, drenaje de componentes
  o manipulación de NAV alcanzable por usuarios públicos.
- Alta: bypass de controles de rebalance, redenciones incorrectas, oráculo
  obsoleto aceptado o emergencia que degrade balances de terceros.
- Media: errores de contabilidad acotados, DoS temporal, límites mal aplicados o
  inconsistencias de reporting que puedan inducir decisiones incorrectas.
- Baja: problemas de documentación, ergonomía de tests, eventos incompletos o
  validaciones defensivas mejorables sin impacto económico directo.

## Verificación local

Antes de reportar o aceptar un cambio, ejecuta las comprobaciones básicas:

```bash
forge fmt --check
forge build
forge test -vvv
```

En PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File ./scripts/tests.ps1
```

Si el hallazgo depende de una condición concreta, adjunta también el comando
Foundry mínimo que reproduce la prueba, por ejemplo:

```bash
forge test --match-test testName -vvvv
```

## Invariantes de seguridad

Los cambios deben preservar las invariantes centrales del índice:

- cada `SINDEX` representa una cuota coherente del portfolio;
- mint y redeem conservan proporcionalidad bajo las reglas configuradas;
- los rebalanceos no permiten extraer componentes por encima de la cuota
  económica correspondiente;
- los precios usados para NAV, límites y salidas respetan heartbeat y rangos
  configurados;
- los permisos administrativos permanecen aislados de rutas públicas de valor;
- las rutas de valor mantienen protecciones contra reentrancy y estados
  inconsistentes.

Las correcciones deben incluir tests que fallen antes del cambio y pasen después,
además de mantener la suite existente en verde.
